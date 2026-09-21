#!/usr/bin/env python3
"""Functional scenarios for the synthetic upstream and finite RTX lab profile."""
import argparse
import asyncio
import json
import ipaddress
from pathlib import Path
import struct
import time
import integration as dns


async def exchange(args, queries, timeout=8):
    """Bound connection setup, request I/O, replies, and normal close together."""
    async def transaction():
        reader, writer = await asyncio.open_connection(args.target, args.port, local_addr=(args.source, 0), limit=131072)
        try:
            writer.write(b''.join(dns.frame(q) for q in queries))
            await writer.drain()
            replies = [await dns.receive(reader) for _ in queries]
        finally:
            # On cancellation, close synchronously and propagate cancellation;
            # do not introduce an unbounded await in the cleanup path.
            writer.close()
        await writer.wait_closed()
        return replies
    return await asyncio.wait_for(transaction(), timeout)


async def raw_request(args, query, timeout=8):
    return (await exchange(args, [query], timeout))[0]


async def main(args):
    nonce = str(time.time_ns())
    mode = Path(args.mode_file)
    def setmode(**options):
        p = mode.with_suffix('.tmp')
        p.write_text(json.dumps(options))
        p.replace(mode)
    try:
        setmode()
        warmup = dns.query(f'r512-warmup-{nonce}.dns-size.invalid', 99)
        assert dns.verify(await raw_request(args, warmup), warmup, 512, 0) == 0
        setmode(reorder=True)
        queries = [dns.query(f'r512-order-{nonce}-{i}.dns-size.invalid',i+100) for i in range(4)]
        order=[]
        for raw in await exchange(args, queries):
            ident=struct.unpack_from('!H',raw)[0]
            assert ident in range(100,104) and ident not in order
            assert dns.verify(raw,queries[ident-100],512,0)==0
            order.append(ident)
        assert order == [103,102,101,100], f'reordered fixture returned {order}'
        dns.emit('scenario_pass',scenario='pipeline_ID_correlation',response_order=order)

        setmode(fragment=113)
        q=dns.query(f'r65535-fragment-{nonce}.dns-size.invalid',900)
        raw=await raw_request(args,q)
        assert dns.verify(raw,q,65535,0)==0
        dns.emit('scenario_pass',scenario='maximum_response_split_length_prefix',size=len(raw))

        setmode()
        name=f'c512-cache-{nonce}.dns-size.invalid'
        q=dns.query(name,910)
        first=await raw_request(args,q)
        assert dns.verify(first,q,512,30)==0
        await asyncio.sleep(2)
        q2=dns.query(name.upper(),911)
        second=await raw_request(args,q2)
        assert dns.verify(second,q2,512,30)==0
        _,qsec=dns.question(second)
        ttl=struct.unpack_from('!I',second,12+len(qsec)+6)[0]
        assert ttl<=29
        dns.emit('scenario_pass',scenario='cache_ID_case_TTL',remaining_ttl=ttl)

        setmode(mode='blackhole')
        badq=dns.query(f'r512-outage-{nonce}.dns-size.invalid',912)
        pending=asyncio.create_task(raw_request(args,badq))
        await asyncio.sleep(.2)
        before=time.monotonic()
        cached=await raw_request(args,dns.query(name,913))
        assert dns.verify(cached,dns.query(name,913),512,30)==0
        localq=dns.query(args.local_name,914)
        localq=localq[:-4]+struct.pack('!HH',1,1)
        localanswer=await raw_request(args,localq)
        assert localanswer[:2]==localq[:2] and localanswer[3]&15==0
        assert args.local_address.packed in localanswer
        elapsed=time.monotonic()-before
        assert elapsed<1.5
        failure=await pending
        assert failure[3]&15==2
        dns.emit('scenario_pass',scenario='upstream_outage_cache_and_local_continue',service_elapsed_ms=round(elapsed*1000,3))
    finally:
        setmode()


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--target',required=True)
    p.add_argument('--source',required=True)
    p.add_argument('--port',type=int,default=53053)
    p.add_argument('--mode-file',required=True)
    p.add_argument('--local-name',required=True,help='Local hostname served by the router DNS')
    p.add_argument('--local-address',required=True,type=ipaddress.IPv4Address,
                   help='Expected IPv4 address for --local-name')
    args=p.parse_args()
    asyncio.run(main(args))
