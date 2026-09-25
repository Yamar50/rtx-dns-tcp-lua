#!/usr/bin/env python3
"""Verify one Release's assets and prepare its immutable installer payload mirror.

The version must be selected explicitly. Pre-releases additionally require
--allow-prerelease. Existing version payloads are never silently replaced.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = 'https://api.github.com/repos/Yamar50/rtx-dns-tcp-lua'


def get(url):
    if not url.startswith('https://'):
        raise ValueError('HTTPS required')
    req = urllib.request.Request(url, headers={'User-Agent': 'rtx-dns-installer-publisher'})
    with urllib.request.urlopen(req, timeout=60) as response:
        if response.status != 200 or not response.url.startswith('https://'):
            raise ValueError('HTTPS download failed')
        data = response.read(1048577)
    if len(data) > 1048576:
        raise ValueError('download exceeds the size limit')
    return data


def prepare(version, allow_prerelease=False, root=ROOT, fetch=get):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('an explicit version such as v0.1.4 is required')
    release = json.loads(fetch(REPO + '/releases/tags/' + version))
    if release.get('tag_name') != version or release.get('draft') is not False:
        raise ValueError('the selected version must identify a published release')
    prerelease = release.get('prerelease')
    if not isinstance(prerelease, bool) or (prerelease and not allow_prerelease):
        raise ValueError('a pre-release requires explicit --allow-prerelease')
    prefix = 'https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/' + version + '/'
    selected = {}
    assets = release.get('assets')
    if not isinstance(assets, list):
        raise ValueError('release asset metadata is missing')
    for name in ('SHA256SUMS', 'rtx-dns.lua'):
        matches = [asset for asset in assets if asset.get('name') == name]
        if len(matches) != 1 or matches[0].get('browser_download_url') != prefix + name:
            raise ValueError('a unique release asset from the selected version is required')
        selected[name] = matches[0]
    files = {}
    for name in ('SHA256SUMS', 'rtx-dns.lua'):
        data = fetch(prefix + name)
        if selected[name].get('size') != len(data):
            raise ValueError('release asset size mismatch')
        api_digest = selected[name].get('digest')
        if api_digest is not None and api_digest != 'sha256:' + hashlib.sha256(data).hexdigest():
            raise ValueError('release asset metadata digest mismatch')
        files[name] = data
    records = []
    for line in files['SHA256SUMS'].decode('ascii').splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *](\S+)', line)
        if not match:
            raise ValueError('malformed SHA256SUMS record')
        if match[2] == 'rtx-dns.lua':
            records.append(match[1].lower())
    digest = hashlib.sha256(files['rtx-dns.lua']).hexdigest()
    if len(records) != 1 or records[0] != digest or not 1024 <= len(files['rtx-dns.lua']) <= 524288:
        raise ValueError('Release checksum mismatch or unsupported payload size')
    files['manifest.txt'] = version.encode('ascii') + b'\n' + files['SHA256SUMS']
    out = root / 'installer/versions' / version
    for name, data in files.items():
        target = out / name
        if target.exists() and target.read_bytes() != data:
            raise ValueError(f'existing {version}/{name} differs; version payloads are immutable')
    out.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        target = out / name
        if not target.exists():
            target.write_bytes(data)
    result = {'version': version, 'prerelease': prerelease, 'bytes': len(files['rtx-dns.lua']),
              'sha256': digest, 'release_assets_verified': True}
    print(json.dumps(result))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--allow-prerelease', action='store_true')
    args = parser.parse_args()
    prepare(args.version, args.allow_prerelease)
