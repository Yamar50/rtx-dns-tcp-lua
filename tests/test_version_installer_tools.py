"""Check immutable version selection across publisher, builder and CLI bootstrap."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


publisher = module('prepare_version_installer')
builder = module('build_installer')
generator = module('installer_command')


class VersionInstallerToolsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.version = 'v0.1.4'
        self.payload = b'-- payload fixture\n' * 80
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.checksums = (self.digest + '  rtx-dns.lua\n').encode()
        self.prerelease = False
        self.draft = False
        self.return_tag = self.version
        self.requests = []
        self.mutate_assets = lambda assets: assets

    def fetch(self, url):
        self.requests.append(url)
        prefix = 'https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/' + self.version + '/'
        if url == publisher.REPO + '/releases/tags/' + self.version:
            assets = [{'name': name, 'browser_download_url': prefix + name, 'size': len(data),
                       'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}
                      for name, data in [('rtx-dns.lua', self.payload), ('SHA256SUMS', self.checksums)]]
            return json.dumps({'tag_name': self.return_tag, 'draft': self.draft,
                               'prerelease': self.prerelease, 'assets': self.mutate_assets(assets)}).encode()
        if url == prefix + 'rtx-dns.lua':
            return self.payload
        if url == prefix + 'SHA256SUMS':
            return self.checksums
        self.fail('unexpected download URL: ' + url)

    def prepare(self, allow=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return publisher.prepare(self.version, allow, self.root, self.fetch)

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, check=True,
                              capture_output=True).stdout.decode().strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'test fixture')
        return self.git('rev-parse', 'HEAD')

    def repo(self):
        self.prepare()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Installer Test')
        self.git('config', 'user.email', 'installer-test@example.invalid')
        (self.root / 'src').mkdir()
        for name in ['installer_sha256', 'installer_http', 'installer']:
            (self.root / 'src' / (name + '.lua')).write_text('-- test module\n' * 100 + 'return {}\n')
        self.payload_ref = self.commit()
        return self.root / 'installer/versions' / self.version

    def build(self, ref=None):
        with contextlib.redirect_stdout(io.StringIO()):
            return builder.build(self.version, ref or self.payload_ref, self.root)

    def test_explicit_release_and_idempotent_preparation(self):
        result = self.prepare()
        self.assertEqual(result['sha256'], self.digest)
        self.assertEqual(result['version'], self.version)
        self.assertFalse(result['prerelease'])
        self.assertEqual(result, self.prepare())
        self.assertTrue(all('/latest' not in url for url in self.requests))

    def test_prerelease_requires_explicit_opt_in(self):
        self.version = self.return_tag = 'v0.9.9'
        self.prerelease = True
        with self.assertRaisesRegex(ValueError, 'allow-prerelease'):
            self.prepare()
        self.assertFalse((self.root / 'installer').exists())
        self.assertTrue(self.prepare(True)['prerelease'])

    def test_changed_version_payload_refused_before_writes(self):
        self.prepare()
        folder = self.root / 'installer/versions' / self.version
        original = {path.name: path.read_bytes() for path in folder.iterdir()}
        self.payload += b'-- changed\n'
        self.checksums = (hashlib.sha256(self.payload).hexdigest() + '  rtx-dns.lua\n').encode()
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.prepare()
        self.assertEqual(original, {path.name: path.read_bytes() for path in folder.iterdir()})

    def test_checksum_mismatch_does_not_create_files(self):
        self.payload += b'-- corrupted\n'
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.prepare()
        self.assertFalse((self.root / 'installer').exists())

    def test_ambiguous_or_malformed_checksum_refused(self):
        for checksums in [self.checksums * 2, b'bad rtx-dns.lua\n']:
            self.checksums = checksums
            with self.subTest(checksums=checksums), self.assertRaises(ValueError):
                self.prepare()
        self.assertFalse((self.root / 'installer').exists())

    def test_wrong_tag_and_draft_refused(self):
        self.return_tag = 'v0.9.9'
        with self.assertRaises(ValueError):
            self.prepare()
        self.return_tag = self.version
        self.draft = True
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse((self.root / 'installer').exists())

    def test_asset_metadata_mismatch_refused(self):
        for key, value in [('browser_download_url', 'https://example.invalid/rtx-dns.lua'),
                           ('size', 0), ('digest', 'sha256:' + '0' * 64)]:
            def mutate(assets):
                assets[0][key] = value
                return assets
            self.mutate_assets = mutate
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.prepare()
        self.assertFalse((self.root / 'installer').exists())

    def test_builder_embeds_version_digest_size_and_immutable_url(self):
        self.repo()
        body = self.build()
        self.assertIn(f'version="{self.version}"'.encode(), body)
        self.assertIn(f'sha256="{self.digest}"'.encode(), body)
        self.assertIn(f'bytes={len(self.payload)}'.encode(), body)
        self.assertIn((self.payload_ref + '/installer/versions/' + self.version + '/rtx-dns.lua').encode(), body)
        self.assertIn(b'-- Bootstrap API: 1\n', body)
        self.assertIn(b'local mode, expected_version = ...', body)
        self.assertIn(b'expected_version == release.version', body)
        self.assertNotIn(b'/latest', body)

    def test_bundle_checks_version_before_start_and_accepts_both_entry_modes(self):
        lua = shutil.which('lua')
        if not lua:
            self.skipTest('Lua interpreter unavailable')
        self.repo()
        (self.root / 'src/installer.lua').write_text(
            'return {run=function(_, mode, env, release)\n'
            'installer_start(mode, env, release)\nreturn true\nend}\n')
        body = self.build().decode('ascii')
        harness = '''
loadstring = loadstring or load
local body = BODY
local starts = 0
local expected_mode = "no"
local expected_memory = true
installer_start = function(mode, env, release)
 assert(mode==expected_mode and release.version=="v0.1.4")
 assert((env~=nil and env.memory_bootstrap==true)==expected_memory)
 starts=starts+1
end
arg = {[1]="invalid-global-mode"}
assert(loadstring(body))("no", "v0.1.4")
assert(starts==1)
local wrong_body = body:gsub("v0%.1%.4", "v0.9.9")
assert(#wrong_body==#body)
local ok,err = pcall(assert(loadstring(wrong_body)), "yes", "v0.1.4")
assert(not ok and tostring(err):find("Installer version mismatch", 1, true))
assert(starts==1)
expected_mode="yes"
expected_memory=false
arg={[1]="yes"}
assert(loadstring(body))()
assert(starts==2)
'''.replace('BODY', '[====[' + body + ']====]')
        result = subprocess.run([lua, '-'], input=harness, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_builder_refuses_uncommitted_payload_change(self):
        folder = self.repo()
        (folder / 'rtx-dns.lua').write_bytes(self.payload + b'-- changed\n')
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.build()
        self.assertFalse((folder / 'rtx-dns-install.lua').exists())

    def test_builder_refuses_committed_mismatch(self):
        folder = self.repo()
        (folder / 'manifest.txt').write_bytes(b'v0.9.9\n' + self.checksums)
        with self.assertRaisesRegex(ValueError, 'manifest version'):
            self.build(self.commit())
        (folder / 'manifest.txt').write_bytes(self.version.encode() + b'\n' + self.checksums)
        (folder / 'rtx-dns.lua').write_bytes(self.payload + b'-- changed\n')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.build(self.commit())

    def test_command_uses_committed_installer_size(self):
        folder = self.repo()
        body = self.build()
        ref = self.commit()
        (folder / 'rtx-dns-install.lua').write_bytes(b'local uncommitted = true\n')
        command = generator.command(self.version, ref, 'no', self.root)
        self.assertIn(f'/{ref}/installer/versions/{self.version}/rtx-dns-install.lua', command)
        self.assertIn(f'#r.body=={len(body)}', command)
        self.assertIn('DNSINSTALL_BOOT="no"', command)
        self.assertIn('assert(loadstring(r.body))(DNSINSTALL_BOOT,"v0.1.4")', command)
        self.assertNotIn('io.open', command)
        self.assertNotIn('dofile', command)
        self.assertNotIn('rt.command', command)
        self.assertLess(len(command), 450)

    def test_command_rejects_unsupported_bootstrap_api(self):
        folder = self.repo()
        body = self.build()
        marker = b'-- Bootstrap API: 1\n'
        for replacement in [b'', b'-- Bootstrap API: 2\n', marker * 2]:
            with self.subTest(replacement=replacement):
                (folder / 'rtx-dns-install.lua').write_bytes(body.replace(marker, replacement))
                with self.assertRaisesRegex(ValueError, 'bootstrap API 1'):
                    generator.command(self.version, self.commit(), 'no', self.root)

    def test_command_rejects_version_and_payload_metadata_mismatch(self):
        folder = self.repo()
        body = self.build()
        (folder / 'rtx-dns-install.lua').write_bytes(body.replace(b'version="v0.1.4"', b'version="v0.9.9"'))
        with self.assertRaisesRegex(ValueError, 'selected version'):
            generator.command(self.version, self.commit(), 'no', self.root)
        (folder / 'rtx-dns-install.lua').write_bytes(body.replace(self.digest.encode(), b'0' * 64))
        with self.assertRaisesRegex(ValueError, 'committed release payload'):
            generator.command(self.version, self.commit(), 'no', self.root)

    def test_no_mutable_version_or_ref_inputs(self):
        for version in ['latest', 'main', '../v0.1.4', 'v0.1.4/other', 'v0.1.4-nvr.1']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                publisher.prepare(version, root=self.root, fetch=self.fetch)
            with self.subTest(version=version), self.assertRaises(ValueError):
                builder.build(version, 'a' * 40, self.root)
            with self.subTest(version=version), self.assertRaises(ValueError):
                generator.command(version, 'a' * 40, 'no', self.root)
        for ref in ['main', 'HEAD', 'a' * 39, 'A' * 40]:
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                builder.build(self.version, ref, self.root)
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                generator.command(self.version, ref, 'no', self.root)

    def test_cli_required_arguments(self):
        for name in ['prepare_version_installer', 'build_installer', 'installer_command']:
            result = subprocess.run(['python3', str(ROOT / 'tools' / (name + '.py'))],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('--version', result.stderr)


if __name__ == '__main__':
    unittest.main()
