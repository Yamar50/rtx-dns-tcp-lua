#!/usr/bin/env python3
"""Copy the latest stable Release's exact assets to the router HTTPS mirror.

Run when publishing a stable release, then review/commit the three output files.
The installer checks GitHub's latest stable tag before accepting this mirror.
Pre-releases do not change this distribution.
"""
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
        return response.read(1048577)

def main():
    release = json.loads(get(REPO + '/releases/latest'))
    tag = release['tag_name']
    assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag), 'stable semantic version required'
    assert not release['draft'] and not release['prerelease'], 'stable published release required'
    prefix = 'https://github.com/Yamar50/rtx-dns-tcp-lua/releases/download/' + tag + '/'
    checksums = get(prefix + 'SHA256SUMS')
    records = [line.split() for line in checksums.decode('ascii').splitlines() if line.strip()]
    selected = [digest for digest, name in records if name.lstrip('*') == 'rtx-dns.lua']
    assert len(selected) == 1 and re.fullmatch('[0-9a-fA-F]{64}', selected[0]), 'unique checksum required'
    body = get(prefix + 'rtx-dns.lua')
    digest = hashlib.sha256(body).hexdigest()
    assert 1024 <= len(body) <= 524288 and digest == selected[0].lower(), 'Release checksum mismatch'
    out = ROOT/'installer/stable'
    out.mkdir(parents=True, exist_ok=True)
    (out/'rtx-dns.lua').write_bytes(body)
    (out/'SHA256SUMS').write_bytes(checksums)
    (out/'manifest.txt').write_bytes(tag.encode('ascii') + b'\n' + checksums)
    print(json.dumps({'version': tag, 'bytes': len(body), 'sha256': digest, 'release_assets_verified': True}))

if __name__ == '__main__':
    main()
