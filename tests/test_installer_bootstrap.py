import importlib.util
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer_command', ROOT/'tools/installer_command.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        def git(*args):
            return subprocess.run(['git', *args], cwd=cls.root, check=True,
                                  capture_output=True).stdout.decode().strip()
        git('init', '-q')
        git('config', 'user.name', 'Installer Test')
        git('config', 'user.email', 'installer-test@example.invalid')
        out = cls.root / 'installer/versions/v0.1.4'
        out.mkdir(parents=True)
        payload = b'-- fixture\n' * 120
        (out / 'rtx-dns.lua').write_bytes(payload)
        git('add', '.')
        git('commit', '-qm', 'test payload')
        payload_ref = git('rev-parse', 'HEAD')
        cls.body = ('-- Installer release: v0.1.4\n-- Bootstrap API: 1\n' + '-- installer fixture\n' * 60 +
                    'local release = {version="v0.1.4",sha256="' + hashlib.sha256(payload).hexdigest() +
                    '",bytes=' + str(len(payload)) + ',url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/' +
                    payload_ref + '/installer/versions/v0.1.4/rtx-dns.lua"}\n' +
                    'local mode, expected_version = ...\n' +
                    'assert(expected_version == release.version, "Installer version mismatch")\n' +
                    'installer_start(mode, release.version)\n')
        (out / 'rtx-dns-install.lua').write_text(cls.body)
        git('add', '.')
        git('commit', '-qm', 'test installer')
        cls.ref = git('rev-parse', 'HEAD')

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, scenario, succeeds, mode='no'):
        lua = shutil.which('lua')
        if not lua:
            self.skipTest('Lua interpreter unavailable')
        command = generator.command('v0.1.4', self.ref, mode, self.root)
        source = command[len("lua -e '"):-1]
        harness = r'''
loadstring = loadstring or load
local case = CASE
local body = BODY
local commands,opens,starts,requests,dofiles = 0,0,0,0,0
local original_arg = {[1]="previous argument"}
arg = original_arg
rt = {
 command = function()
  commands=commands+1
  error("bootstrap must not call rt.command")
 end,
 httprequest = function(req)
  requests=requests+1
  assert(req.url==URL and req.method=="GET" and req.timeout==30)
  if case=="transport" then return {rtn1=false,code=200,body=body} end
  if case=="http" then return {rtn1=true,code=404,body=body} end
  if case=="missing-body" then return {rtn1=true,code=200} end
  if case=="nonstring-body" then return {rtn1=true,code=200,body={}} end
  if case=="short" then return {rtn1=true,code=200,body="short"} end
  if case=="syntax" then return {rtn1=true,code=200,body=body:sub(1,-2).."!"} end
  if case=="wrong-version" then return {rtn1=true,code=200,body=body:gsub("v0%.1%.4","v0.9.9")} end
  return {rtn1=true,code=200,body=body}
 end
}
io = {open=function()
 opens=opens+1
 error("bootstrap must not open files")
end}
dofile=function()
 dofiles=dofiles+1
 error("bootstrap must not call dofile")
end
installer_start=function(mode,version)
 assert(mode==MODE and version=="v0.1.4")
 starts=starts+1
end
local f=assert(loadstring(SOURCE))
local ok,err=pcall(f)
assert(ok==SUCCEEDS)
assert(requests==1 and commands==0 and opens==0 and dofiles==0)
assert(arg==original_arg and arg[1]=="previous argument")
if ok then assert(starts==1)
else
 assert(starts==0)
 if case=="wrong-version" then assert(tostring(err):find("Installer version mismatch",1,true))
 elseif case~="syntax" then assert(tostring(err):find("Installer download failed",1,true)) end
end
'''
        def literal(s):
            return '[====[' + s + ']====]'
        url = f'https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/{self.ref}/installer/versions/v0.1.4/rtx-dns-install.lua'
        harness = harness.replace('CASE', literal(scenario)).replace('SOURCE', literal(source)).replace('BODY', literal(self.body)).replace('SUCCEEDS', 'true' if succeeds else 'false').replace('MODE', literal(mode)).replace('URL', literal(url))
        result = subprocess.run([lua, '-'], input=harness, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bootstrap_validation_before_in_memory_execution(self):
        for scenario in ['transport', 'http', 'missing-body', 'nonstring-body', 'short', 'syntax', 'wrong-version', 'success']:
            with self.subTest(scenario=scenario):
                self.run_case(scenario, scenario == 'success')

    def test_bootstrap_passes_yes_mode(self):
        self.run_case('success', True, 'yes')

    def test_only_explicit_mode_and_immutable_ref(self):
        for ref, mode in [('main', 'yes'), ('a'*40, 'maybe'), ('a'*39, 'yes')]:
            with self.assertRaises(ValueError):
                generator.command('v0.1.4', ref, mode)


if __name__ == '__main__':
    unittest.main()
