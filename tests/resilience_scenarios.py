#!/usr/bin/env python3
"""Finite failure/idle/capacity scenarios for an otherwise idle synthetic lab.

Requires the updated integration.py fixture, its mode/stats files, and the
existing finite RTX lab relay. Never run alongside a throughput stage:
this intentionally changes both synthetic upstreams' behavior. It restores the
original mode file in finally and does not configure the router.
"""
import argparse
import asyncio
import collections
import contextlib
import json
import math
from pathlib import Path
import struct
import time

import integration as dns
import live_scenarios as live


class Scenarios:
    def __init__(self, args):
        self.args = args
        self.mode_path = Path(args.mode_file)
        self.stats_path = Path(args.stats_file)
        self.original_mode = self.mode_path.read_bytes() if self.mode_path.exists() else None
        self.nonce = str(time.time_ns())
        self.serial = 0

    def set_mode(self, primary='healthy', secondary='healthy'):
        value = {'mode': 'healthy', 'ports': {
            str(self.args.primary_port): {'mode': primary},
            str(self.args.secondary_port): {'mode': secondary}}}
        temporary = self.mode_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(value))
        temporary.replace(self.mode_path)

    def restore_mode(self):
        if self.original_mode is None:
            self.mode_path.unlink(missing_ok=True)
        else:
            temporary = self.mode_path.with_suffix('.tmp')
            temporary.write_bytes(self.original_mode)
            temporary.replace(self.mode_path)

    def query(self, label, cached=False, ident=None):
        self.serial += 1
        name = f"{'c' if cached else 'r'}512-{label}-{self.nonce}-{self.serial}.dns-size.invalid"
        return dns.query(name, self.serial % 65536 if ident is None else ident)

    async def request(self, query, ttl=0):
        start = time.monotonic()
        raw = await live.raw_request(self.args, query, timeout=self.args.timeout)
        return dns.verify(raw, query, 512, ttl), raw, time.monotonic() - start

    def read_stats(self):
        data = json.loads(self.stats_path.read_text())
        assert 'ports' in data, 'restart the fixture with per-port statistics before this test'
        return data

    async def snapshot(self):
        """Wait for a publication after the call, so completed work is counted."""
        after = time.time()
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                data = self.read_stats()
            except (FileNotFoundError, json.JSONDecodeError):
                data = None
            if data and data['epoch'] >= after:
                return data
            await asyncio.sleep(.05)
        raise AssertionError('fixture statistics did not update within four seconds')

    @staticmethod
    def port(data, port, field):
        return data['ports'].get(str(port), {}).get(field, 0)

    def total(self, data, field):
        return sum(self.port(data, port, field) for port in (self.args.primary_port, self.args.secondary_port))

    async def primary_healthy(self):
        """Demand-driven recovery may wait for the configured 30-second pause."""
        self.set_mode()
        before = await self.snapshot()
        baseline = self.port(before, self.args.primary_port, 'responses')
        deadline = time.monotonic() + self.args.recovery_timeout
        while time.monotonic() < deadline:
            try:
                code, _, _ = await self.request(self.query('recover'))
            except (ConnectionError, asyncio.TimeoutError, OSError):
                code = None
            after = await self.snapshot()
            if code == 0 and self.port(after, self.args.primary_port, 'responses') > baseline:
                return after
            await asyncio.sleep(.2)
        raise AssertionError('primary did not recover within the bounded observation period')

    async def primary_failure(self, behavior):
        before = await self.primary_healthy()
        self.set_mode(primary=behavior)
        code, _, elapsed = await self.request(self.query(behavior))
        assert code == 0, f'healthy secondary did not answer after primary {behavior}: RCODE {code}'
        after = await self.snapshot()
        primary_queries = self.port(after, self.args.primary_port, 'queries') - self.port(before, self.args.primary_port, 'queries')
        secondary_queries = self.port(after, self.args.secondary_port, 'queries') - self.port(before, self.args.secondary_port, 'queries')
        secondary_responses = self.port(after, self.args.secondary_port, 'responses') - self.port(before, self.args.secondary_port, 'responses')
        assert primary_queries == 1 and secondary_queries == 1 and secondary_responses == 1, (primary_queries, secondary_queries, secondary_responses)
        assert elapsed < self.args.timeout
        dns.emit('scenario_pass', scenario=f'primary_{behavior}_secondary_healthy', primary_queries=primary_queries,
                 secondary_queries=secondary_queries, elapsed_ms=round(elapsed * 1000, 3))

    async def both_close(self):
        before = await self.primary_healthy()
        self.set_mode(primary='close', secondary='close')
        start = time.monotonic()
        results, failures, tasks = collections.Counter(), collections.Counter(), []

        async def one():
            try:
                code, _, _ = await self.request(self.query('both-close'))
                results[code] += 1
            except Exception as exc:
                failures[type(exc).__name__] += 1

        count = math.ceil(self.args.close_rate * self.args.close_duration)
        for index in range(count):
            await asyncio.sleep(max(0, start + index / self.args.close_rate - time.monotonic()))
            tasks.append(asyncio.create_task(one()))
        await asyncio.gather(*tasks)
        elapsed = time.monotonic() - start
        after = await self.snapshot()
        accepted = self.total(after, 'accepted') - self.total(before, 'accepted')
        queries = self.total(after, 'queries') - self.total(before, 'queries')
        # Successful TCP accepts lower-bound actual dial attempts. In this local
        # fixture every listening-port connection can be accepted, making this a
        # useful live check alongside the exact mock token-bucket tests.
        assert accepted <= math.ceil(elapsed) + 2, (accepted, elapsed)
        assert queries <= 2 * count, 'more than two upstream attempts per request in aggregate'
        assert not failures and results == {2: count}, (dict(results), dict(failures))
        dns.emit('scenario_pass', scenario='both_peers_close_bounded_reconnects', requests=count,
                 elapsed=elapsed, new_fixture_connections=accepted, upstream_queries=queries,
                 rcode_counts=dict(results), transport_errors=dict(failures))

    async def idle_reconnect(self):
        before = await self.primary_healthy()
        assert self.total(before, 'active') >= 1
        dns.emit('scenario_wait', scenario='idle_30_seconds', seconds=self.args.idle_wait)
        await asyncio.sleep(self.args.idle_wait)
        idle = await self.snapshot()
        assert self.total(idle, 'active') == 0, 'upstream sockets remained open past idle deadline'
        code, _, elapsed = await self.request(self.query('after-idle'))
        assert code == 0
        after = await self.snapshot()
        accepted = self.total(after, 'accepted') - self.total(idle, 'accepted')
        assert accepted == 1, f'idle reconnect should use one new primary connection, got {accepted}'
        dns.emit('scenario_pass', scenario='idle_close_and_next_query_reconnect', idle_wait=self.args.idle_wait,
                 new_fixture_connections=accepted, elapsed_ms=round(elapsed * 1000, 3))

    async def cache_under_capacity(self):
        await self.primary_healthy()
        cached_query = self.query('capacity-cache', cached=True)
        code, _, _ = await self.request(cached_query, ttl=30)
        assert code == 0
        self.set_mode(primary='blackhole', secondary='blackhole')
        writers, readers, questions, read_tasks = [], [], {}, []
        start = time.monotonic()
        try:
            # Nine clients x four messages exceed 32 pending slots while staying
            # below 32 client sockets. At least one immediate SERVFAIL therefore
            # demonstrates capacity pressure before the two-second upstream timer.
            for _ in range(9):
                reader, writer = await asyncio.wait_for(asyncio.open_connection(
                    self.args.target, self.args.port, local_addr=(self.args.source, 0), limit=131072), 1)
                writers.append(writer)
                readers.append(reader)
                batch = [self.query('capacity-held') for _ in range(4)]
                questions.update({struct.unpack_from('!H', q)[0]: q for q in batch})
                writer.write(b''.join(dns.frame(q) for q in batch))
                await asyncio.wait_for(writer.drain(), 1)
            read_tasks = [asyncio.create_task(dns.receive(reader)) for reader in readers]
            done, _ = await asyncio.wait(read_tasks, timeout=.75, return_when=asyncio.FIRST_COMPLETED)
            assert done, 'no immediate capacity rejection before upstream timeout'
            overflow = next(iter(done)).result()
            ident = struct.unpack_from('!H', overflow)[0]
            assert dns.verify(overflow, questions[ident], 512, 0) == 2
            overload_elapsed = time.monotonic() - start
            assert overload_elapsed < .9, 'cannot distinguish capacity rejection from later timeout'
            code, _, cached_elapsed = await self.request(cached_query, ttl=30)
            assert code == 0 and cached_elapsed < .5
            phase_elapsed = time.monotonic() - start
            assert phase_elapsed < .9, 'cache response arrived too late to prove pending slots were still held'
            dns.emit('scenario_pass', scenario='cache_hit_during_pending_capacity_pressure', submitted_uncached=36,
                     overload_elapsed_ms=round(overload_elapsed * 1000, 3), cached_elapsed_ms=round(cached_elapsed * 1000, 3),
                     phase_elapsed_ms=round(phase_elapsed * 1000, 3))
        finally:
            for task in read_tasks:
                task.cancel()
            await asyncio.gather(*read_tasks, return_exceptions=True)
            for writer in writers:
                writer.close()
            for writer in writers:
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(writer.wait_closed(), .2)
            self.set_mode()
        await self.primary_healthy()

    async def run(self):
        try:
            await self.snapshot()
            for name, operation in (
                ('primary_close', lambda: self.primary_failure('close')),
                ('primary_truncate', lambda: self.primary_failure('truncate')),
                ('both_close', self.both_close),
                ('idle_reconnect', self.idle_reconnect),
                ('cache_capacity', self.cache_under_capacity),
            ):
                if self.args.scenario in ('all', name):
                    dns.emit('scenario_start', scenario=name)
                    await operation()
            dns.emit('resilience_complete')
        finally:
            self.restore_mode()
            dns.emit('fixture_mode_restored')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--port', type=int, default=53053)
    parser.add_argument('--mode-file', required=True)
    parser.add_argument('--stats-file', required=True)
    parser.add_argument('--primary-port', type=int, default=15353)
    parser.add_argument('--secondary-port', type=int, default=15354)
    parser.add_argument('--timeout', type=float, default=8)
    parser.add_argument('--recovery-timeout', type=float, default=35)
    parser.add_argument('--idle-wait', type=float, default=32)
    parser.add_argument('--close-rate', type=float, default=10)
    parser.add_argument('--close-duration', type=float, default=8)
    parser.add_argument('--total-timeout', type=float, default=240)
    parser.add_argument('--scenario', choices=['all', 'primary_close', 'primary_truncate', 'both_close', 'idle_reconnect', 'cache_capacity'], default='all')
    args = parser.parse_args()
    assert args.idle_wait >= 31, 'allow at least one second beyond the 30-second idle deadline'
    assert 0 < args.close_rate <= 20 and 0 < args.close_duration <= 30
    scenarios = Scenarios(args)
    asyncio.run(asyncio.wait_for(scenarios.run(), args.total_timeout))


if __name__ == '__main__':
    main()
