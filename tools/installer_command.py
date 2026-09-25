#!/usr/bin/env python3
"""Print a pinned one-line Yamaha CLI bootstrap (yes/no selects autostart)."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def command(ref, mode, size=None):
    if not re.fullmatch('[0-9a-f]{40}', ref):
        raise ValueError('use a reviewed, immutable 40-character commit ID')
    if mode not in ('yes', 'no'):
        raise ValueError('mode must be yes or no')
    size = size or (ROOT/'installer/rtx-dns-install.lua').stat().st_size
    url = f'https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/{ref}/installer/rtx-dns-install.lua'
    script = (
        f'local DNSINSTALL_BOOT="{mode}";local p="/lua/rtx-dns-install.lua";'
        'local function guard()local ok,s=rt.command("show status lua running","off");assert(ok and s);local n=0;'
        'for l in s:gmatch("[^"..string.char(13,10).."]+")do '
        'assert(l:match(":%s*(/%S+)%s*$")~=p,"Installer already running");'
        'if l:find("lua %-e ")and l:find("local DNSINSTALL_BOOT=",1,true)then n=n+1 end end;'
        'assert(n<=1,"Installer already running")end;guard();'
        f'local r=rt.httprequest({{url="{url}",method="GET",timeout=30}});'
        f'assert(r.rtn1 and r.code==200 and type(r.body)=="string" and #r.body=={size},"Installer download failed");'
        'assert(loadstring(r.body));guard();rt.command("make directory /lua","off");'
        'local f=assert(io.open(p,"wb"));assert(f:write(r.body));assert(f:close());'
        'f=assert(io.open(p,"rb"));assert(f:read("*a")==r.body);assert(f:close());'
        'arg={[0]=p,[1]=DNSINSTALL_BOOT};dofile(p)'
    )
    assert len(script) < 4095 and "'" not in script and '?' not in script and '\\' not in script
    return "lua -e '" + script + "'"

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--mode', choices=('yes', 'no'), default='yes')
    args = parser.parse_args()
    print(command(args.ref, args.mode))
