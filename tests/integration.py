#!/usr/bin/env python3
"""Finite LAN-only DNS fixture and open-loop client; Python standard library."""
import argparse
import asyncio
import collections
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import time


def emit(event, **data):
    print(json.dumps(dict(event=event, epoch=time.time(), **data), sort_keys=True), flush=True)


def question(raw):
    if len(raw) < 17 or struct.unpack_from('!H', raw, 4)[0] != 1:
        raise ValueError('one question required')
    p, labels = 12, []
    while p < len(raw) and raw[p]:
        n = raw[p]
        if n > 63 or p + n + 1 >= len(raw):
            raise ValueError('question label')
        labels.append(raw[p+1:p+1+n].decode('ascii'))
        p += n + 1
    if p + 5 > len(raw):
        raise ValueError('truncated question')
    return '.'.join(labels).lower(), raw[12:p+5]


def skip_name(raw, position):
    """Validate an RR owner name, including bounded backwards compression."""
    end, expanded, visited = None, 0, set()
    while True:
        if position >= len(raw) or position in visited:
            raise ValueError('truncated or cyclic name')
        visited.add(position)
        length = raw[position]
        if length & 0xc0 == 0xc0:
            if position + 1 >= len(raw):
                raise ValueError('truncated name pointer')
            target = ((length & 0x3f) << 8) | raw[position+1]
            if target < 12 or target >= position:
                raise ValueError('invalid name pointer')
            if end is None:
                end = position + 2
            position = target
            continue
        if length > 63 or position + length + 1 > len(raw):
            raise ValueError('invalid name label')
        expanded += length + 1
        if expanded > 255:
            raise ValueError('name exceeds 255 bytes')
        position += length + 1
        if not length:
            return position if end is None else end


def validate_response(raw, q):
    """Check framing-independent DNS structure before classifying any RCODE."""
    if len(raw) < 12 or len(raw) > 65535 or len(q) < 12:
        raise ValueError('truncated DNS header')
    ident, flags, qd, an, ns, ar = struct.unpack_from('!6H', raw)
    qident, qflags = struct.unpack_from('!2H', q)
    if ident != qident:
        raise ValueError('ID mismatch')
    if not flags & 0x8000 or flags & 0x7800 != qflags & 0x7800:
        raise ValueError('response QR or opcode mismatch')
    if flags & 0x0240:
        raise ValueError('truncated response or reserved header flag')
    if flags & 0x0100 != qflags & 0x0100:
        raise ValueError('response RD mismatch')
    if qd != 1:
        raise ValueError('one response question required')
    _, actual_question = question(raw)
    _, expected_question = question(q)
    if (actual_question[:-4].lower() != expected_question[:-4].lower()
            or actual_question[-4:] != expected_question[-4:]):
        raise ValueError('response question mismatch')
    position = 12 + len(actual_question)
    for _ in range(an + ns + ar):
        position = skip_name(raw, position)
        if position + 10 > len(raw):
            raise ValueError('truncated resource record header')
        rdlength = struct.unpack_from('!H', raw, position + 8)[0]
        position += 10 + rdlength
        if position > len(raw):
            raise ValueError('truncated resource record data')
    if position != len(raw):
        raise ValueError('unexpected trailing DNS data')
    return flags & 15, actual_question


def query(name, ident):
    labels = b''.join(bytes([len(s)]) + s.encode('ascii') for s in name.split('.')) + b'\0'
    return struct.pack('!6H', ident, 0x100, 1, 0, 0, 0) + labels + struct.pack('!HH', 16, 1)


def answer(q, size, ttl=0):
    name, qsec = question(q)
    remaining = size - 24 - len(qsec)
    if not 1 <= remaining <= 65535 or size > 65535:
        raise ValueError('response size')
    payload = hashlib.shake_256(name.encode()).digest(remaining)
    data, pos = bytearray(), 0
    while remaining:
        count = min(255, remaining - 1)
        data.append(count)
        data.extend(payload[pos:pos+count])
        remaining -= count + 1
        pos += count
    return (q[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0) + qsec + b'\xc0\x0c'
            + struct.pack('!HHIH', 16, 1, ttl, len(data)) + data)


def frame(raw):
    return struct.pack('!H', len(raw)) + raw


async def receive(reader):
    n = struct.unpack('!H', await reader.readexactly(2))[0]
    return await reader.readexactly(n)


def verify(raw, q, size, ttl):
    rcode, qsec = validate_response(raw, q)
    if rcode:
        return rcode
    offset = 12 + len(qsec) + 6
    actual_ttl = struct.unpack_from('!I', raw, offset)[0]
    if not 0 <= actual_ttl <= ttl:
        raise ValueError('TTL mismatch')
    expected = answer(q, size, actual_ttl)
    if raw != expected:
        raise ValueError('response byte mismatch')
    return 0


def port_options(options, port):
    """A port override inherits unspecified global fixture options."""
    merged = {key: value for key, value in options.items() if key != 'ports'}
    merged.update(options.get('ports', {}).get(str(port), {}))
    return merged


async def serve(args):
    stats = collections.Counter()
    port_stats = collections.defaultdict(collections.Counter)
    handlers, writers, responses = set(), set(), set()
    deadline = time.monotonic() + args.duration
    def mode():
        if not args.mode_file:
            return {}
        try:
            return json.loads(Path(args.mode_file).read_text())
        except FileNotFoundError:
            return {}

    def port_mode(port):
        return port_options(mode(), port)

    def counters_by_port():
        return {str(port): dict(values) for port, values in port_stats.items()}

    async def handle(reader, writer):
        task = asyncio.current_task()
        handlers.add(task)
        peer = writer.get_extra_info('peername')
        local = writer.get_extra_info('sockname')
        port = local[1] if local else 0
        def count(key, amount=1):
            stats[key] += amount
            port_stats[port][key] += amount
        def peak(key, value):
            stats[key] = max(stats[key], value)
            port_stats[port][key] = max(port_stats[port][key], value)
        if not peer or peer[0] not in args.allow:
            count('rejected')
            writer.close()
            handlers.discard(task)
            return
        writers.add(writer)
        count('accepted')
        count('active')
        stats['max_active'] = max(stats['max_active'], stats['active'])
        port_stats[port]['max_active'] = max(port_stats[port]['max_active'], port_stats[port]['active'])
        lock, pending, reorder_waiting = asyncio.Lock(), set(), []

        async def respond(q):
            opts = port_mode(port)
            behavior = opts.get('mode', 'healthy')
            name, _ = question(q)
            found = re.match(r'[rc](\d+)-', name)
            if not found:
                raise ValueError('fixture name required')
            size = int(found[1])
            ttl = int(opts.get('ttl', 30 if name.startswith('c') else 0))
            if behavior == 'blackhole':
                await asyncio.sleep(8)
                return
            if behavior == 'close':
                writer.close()
                return
            if opts.get('reorder'):
                # A four-query barrier proves pipeline support and makes the
                # response order deterministic, independent of scheduler delay.
                ready = asyncio.get_running_loop().create_future()
                reorder_waiting.append((frame(answer(q, size, ttl)), ready))
                if len(reorder_waiting) == 4:
                    batch = list(reversed(reorder_waiting))
                    reorder_waiting.clear()
                    async with lock:
                        writer.write(b''.join(raw for raw, _ in batch))
                        await writer.drain()
                        count('responses', len(batch))
                        count('dns_bytes', sum(len(raw) - 2 for raw, _ in batch))
                    for _, future in batch:
                        if not future.done():
                            future.set_result(None)
                await ready
                return
            await asyncio.sleep(float(opts.get('delay', 0)))
            raw = frame(answer(q, size, ttl))
            async with lock:
                if behavior == 'truncate':
                    writer.write(raw[:20])
                    await writer.drain()
                    writer.close()
                    return
                fragment = int(opts.get('fragment', 0))
                if fragment:
                    writer.write(raw[:1])
                    await writer.drain()
                    await asyncio.sleep(.02)
                    for p in range(1, len(raw), fragment):
                        writer.write(raw[p:p+fragment])
                        await writer.drain()
                else:
                    writer.write(raw)
                    await writer.drain()
                count('responses')
                count('dns_bytes', len(raw) - 2)

        try:
            while time.monotonic() < deadline:
                q = await asyncio.wait_for(receive(reader), 65)
                if len(q) > 4096:
                    raise ValueError('query too large')
                count('queries')
                if len(pending) >= 32:
                    raise ValueError('too many fixture requests')
                job = asyncio.create_task(respond(q))
                pending.add(job)
                responses.add(job)
                def done(t):
                    pending.discard(t)
                    responses.discard(t)
                    if not t.cancelled() and t.exception():
                        count('response_errors')
                job.add_done_callback(done)
                peak('max_pending_per_connection', len(pending))
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.TimeoutError):
            pass
        except Exception:
            count('handler_errors')
        finally:
            for t in list(pending):
                t.cancel()
            await asyncio.gather(*list(pending), return_exceptions=True)
            writer.close()
            writers.discard(writer)
            handlers.discard(task)
            count('active', -1)

    servers = [await asyncio.start_server(handle, args.bind, port, limit=131072) for port in args.ports]
    emit('ready', bind=args.bind, ports=args.ports, pid=os.getpid())
    try:
        while time.monotonic() < deadline:
            await asyncio.sleep(1)
            data = dict(epoch=time.time(), stats=dict(stats), ports=counters_by_port(), mode=mode())
            if args.stats_file:
                p = Path(args.stats_file)
                p.with_suffix('.tmp').write_text(json.dumps(data))
                p.with_suffix('.tmp').replace(p)
            if int(time.monotonic()) % 10 == 0:
                emit('progress', **{k: v for k, v in data.items() if k != 'epoch'})
    finally:
        for server in servers:
            server.close()
            await server.wait_closed()
        for writer in writers.copy():
            writer.close()
        for task in handlers.copy():
            task.cancel()
        await asyncio.gather(*handlers, return_exceptions=True)
        emit('final', stats=dict(stats), ports=counters_by_port())


async def request(args, name, ident):
    q = query(name, ident)
    reader, writer = await asyncio.open_connection(args.target, args.port, local_addr=(args.source, 0), limit=131072)
    try:
        writer.write(frame(q))
        await writer.drain()
        raw = await receive(reader)
        return verify(raw, q, args.size, 30 if name.startswith('c') else 0), raw
    finally:
        writer.close()
        await writer.wait_closed()


async def stage(args):
    start = time.monotonic()
    stats, errors, durations = collections.Counter(), collections.Counter(), []
    running = set()
    total = math.ceil(args.rate * args.duration)
    nonce = str(time.time_ns())
    emit('stage_start', label=args.label, rate=args.rate, duration=args.duration, size=args.size, planned=total)
    async def run_one(i):
        before = time.monotonic()
        try:
            name = f"{'c' if args.cache else 'r'}{args.size}-{nonce}-{0 if args.cache else i}.dns-size.invalid"
            code, _ = await asyncio.wait_for(request(args, name, i % 65536), args.timeout)
            stats['success' if code == 0 else f'rcode_{code}'] += 1
            durations.append(time.monotonic() - before)
        except Exception as exc:
            errors[type(exc).__name__] += 1
        finally:
            stats['completed'] += 1
    for i in range(total):
        when = start + i / args.rate
        await asyncio.sleep(max(0, when - time.monotonic()))
        if time.monotonic() - when > .1:
            stats['generator_skips'] += 1
            continue
        if len(running) >= args.max_inflight:
            stats['capacity_drops'] += 1
            continue
        stats['started'] += 1
        task = asyncio.create_task(run_one(i))
        running.add(task)
        task.add_done_callback(running.discard)
    await asyncio.gather(*running)
    durations.sort()
    pct = lambda p: round(durations[max(0, math.ceil(len(durations)*p)-1)]*1000, 3) if durations else None
    emit('stage_result', label=args.label, stats=dict(stats), errors=dict(errors), elapsed=time.monotonic()-start,
         p50_ms=pct(.5), p95_ms=pct(.95), p99_ms=pct(.99), planned=total)
    if args.require_success and stats['success'] != total:
        raise SystemExit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    s = sub.add_parser('serve')
    s.add_argument('--bind', required=True)
    s.add_argument('--ports', type=int, nargs='+', default=[15353,15354])
    s.add_argument('--allow', action='append', required=True)
    s.add_argument('--duration', type=int, default=7200)
    s.add_argument('--mode-file')
    s.add_argument('--stats-file')
    c = sub.add_parser('stage')
    c.add_argument('--target', required=True)
    c.add_argument('--source', required=True)
    c.add_argument('--port', type=int, default=53053)
    c.add_argument('--size', type=int, default=512)
    c.add_argument('--rate', type=float, default=10)
    c.add_argument('--duration', type=float, default=10)
    c.add_argument('--timeout', type=float, default=8)
    c.add_argument('--max-inflight', type=int, default=1024)
    c.add_argument('--cache', action='store_true')
    c.add_argument('--require-success', action='store_true')
    c.add_argument('--label', default='stage')
    a = p.parse_args()
    try:
        asyncio.run(serve(a) if a.command == 'serve' else stage(a))
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
