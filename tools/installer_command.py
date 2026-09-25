#!/usr/bin/env python3
"""Print a pinned one-line Yamaha CLI bootstrap (yes/no selects autostart)."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def command(version, ref, mode, root=ROOT):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('an explicit version such as v0.1.4 is required')
    if not re.fullmatch('[0-9a-f]{40}', ref):
        raise ValueError('use a reviewed, immutable 40-character commit ID')
    if mode not in ('yes', 'no'):
        raise ValueError('mode must be yes or no')
    kind = subprocess.run(['git', 'cat-file', '-t', ref], cwd=root,
                          check=True, capture_output=True).stdout.strip()
    if kind != b'commit':
        raise ValueError('ref must identify a commit')
    relative = f'installer/versions/{version}/rtx-dns-install.lua'
    body = subprocess.run(['git', 'show', f'{ref}:{relative}'], cwd=root,
                          check=True, capture_output=True).stdout
    if re.findall(rb'^-- Bootstrap API: ([0-9]+)$', body, re.MULTILINE) != [b'1']:
        raise ValueError('installer does not support bootstrap API 1')
    metadata = re.findall(rb'^local release = \{version="([^"]+)",sha256="([0-9a-f]{64})",bytes=([0-9]+),url="([^"]+)"\}$', body, re.MULTILINE)
    if len(metadata) != 1 or metadata[0][0].decode('ascii') != version:
        raise ValueError('installer metadata does not match the selected version')
    payload_url = metadata[0][3].decode('ascii')
    payload_match = re.fullmatch(r'https://raw\.githubusercontent\.com/Yamar50/rtx-dns-tcp-lua/([0-9a-f]{40})/(installer/versions/' + re.escape(version) + r'/rtx-dns\.lua)', payload_url)
    if not payload_match:
        raise ValueError('installer payload URL is not immutable or does not match its version')
    payload = subprocess.run(['git', 'show', f'{payload_match[1]}:{payload_match[2]}'],
                             cwd=root, check=True, capture_output=True).stdout
    if (hashlib.sha256(payload).hexdigest().encode('ascii') != metadata[0][1]
            or len(payload) != int(metadata[0][2])):
        raise ValueError('installer metadata does not match the committed release payload')
    size = len(body)
    if not 1024 <= size <= 262144:
        raise ValueError('installer size is outside the supported range')
    url = f'https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/{ref}/{relative}'
    script = (
        f'local DNSINSTALL_BOOT="{mode}";'
        f'local r=rt.httprequest({{url="{url}",method="GET",timeout=30}});'
        f'assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body=={size},"Installer download failed");'
        f'assert(loadstring(r.body))(DNSINSTALL_BOOT,"{version}")'
    )
    assert len(script) < 4095 and "'" not in script and '?' not in script and '\\' not in script
    return "lua -e '" + script + "'"

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--mode', choices=('yes', 'no'), required=True)
    args = parser.parse_args()
    print(command(args.version, args.ref, args.mode))
