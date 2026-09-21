"""Offline checks for synthetic DNS fixtures and load-result accounting.

These tests use no router, network listener, or running experiment resources.
Run with: python3 -m unittest discover -s tests -p 'test_harness.py'
"""
import asyncio
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("offline_integration_fixture", ROOT / "tests" / "integration.py")
dns = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dns)
LIVE_SPEC = importlib.util.spec_from_file_location("offline_live_scenarios", ROOT / "tests" / "live_scenarios.py")
live = importlib.util.module_from_spec(LIVE_SPEC)
with mock.patch.dict(sys.modules, {"integration": dns}):
    LIVE_SPEC.loader.exec_module(live)
RESILIENCE_SPEC = importlib.util.spec_from_file_location("offline_resilience_scenarios", ROOT / "tests" / "resilience_scenarios.py")
resilience = importlib.util.module_from_spec(RESILIENCE_SPEC)
with mock.patch.dict(sys.modules, {"integration": dns, "live_scenarios": live}):
    RESILIENCE_SPEC.loader.exec_module(resilience)


class FixtureTests(unittest.TestCase):
    def test_port_mode_inherits_defaults_without_changing_other_ports(self):
        options = {"mode": "blackhole", "ttl": 17, "ports": {"15354": {"mode": "healthy"}}}
        self.assertEqual(dns.port_options(options, 15353), {"mode": "blackhole", "ttl": 17})
        self.assertEqual(dns.port_options(options, 15354), {"mode": "healthy", "ttl": 17})
        self.assertEqual(options["mode"], "blackhole")
        self.assertEqual(dns.port_options({}, 15353), {})
        self.assertEqual(dns.port_options({"mode": "truncate"}, 15353), {"mode": "truncate"})

    def test_exact_message_sizes_and_txt_boundaries(self):
        for size in (512, 4096, 65535):
            with self.subTest(size=size):
                query = dns.query(f"r{size}-offline.dns-size.invalid", 65535)
                response = dns.answer(query, size)
                self.assertEqual(len(response), size)
                self.assertEqual(len(dns.frame(response)), size + 2)
                self.assertEqual(dns.verify(response, query, size, 0), 0)
                _, qsec = dns.question(response)
                start = 12 + len(qsec)
                rdata_length = struct.unpack_from("!H", response, start + 10)[0]
                position, end = start + 12, start + 12 + rdata_length
                while position < end:
                    position += 1 + response[position]
                    self.assertLessEqual(position, end)
                self.assertEqual(position, size)

    def test_verification_rejects_corrupted_bytes_wrong_id_and_ttl(self):
        query = dns.query("c512-offline.dns-size.invalid", 7)
        raw = dns.answer(query, 512, 30)
        self.assertEqual(dns.verify(raw, query, 512, 30), 0)
        for changed in (b"\0\10" + raw[2:], raw[:-1] + bytes([raw[-1] ^ 1]), dns.answer(query, 512, 31)):
            with self.assertRaises(ValueError):
                dns.verify(changed, query, 512, 30)

    def test_query_case_preserved_but_payload_seed_is_case_insensitive(self):
        lower = dns.query("c512-case.dns-size.invalid", 8)
        upper = dns.query("C512-CASE.DNS-SIZE.INVALID", 8)
        lower_name, lower_question = dns.question(lower)
        upper_name, upper_question = dns.question(upper)
        self.assertEqual(lower_name, upper_name)
        self.assertNotEqual(lower_question, upper_question)
        a, b = dns.answer(lower, 512, 30), dns.answer(upper, 512, 30)
        self.assertEqual(a[12 + len(lower_question):], b[12 + len(upper_question):])
        self.assertEqual(dns.verify(b, upper, 512, 30), 0)

    def test_servfail_requires_valid_header_question_and_record_boundaries(self):
        query = dns.query("r512-errors.dns-size.invalid", 123)
        _, qsec = dns.question(query)
        valid = query[:2] + struct.pack("!5H", 0x8182, 1, 0, 0, 0) + qsec
        self.assertEqual(dns.verify(valid, query, 512, 0), 2)
        malformed = [
            query[:2] + bytes([0, 2]),
            query[:2] + struct.pack("!5H", 0x0182, 1, 0, 0, 0) + qsec,
            query[:2] + struct.pack("!5H", 0x8982, 1, 0, 0, 0) + qsec,
            query[:2] + struct.pack("!5H", 0x8182, 0, 0, 0, 0) + qsec,
            query[:2] + struct.pack("!5H", 0x8382, 1, 0, 0, 0) + qsec,
            valid[:-4] + struct.pack("!HH", 1, 1),
            valid + b"trailing bytes",
            query[:2] + struct.pack("!5H", 0x8182, 1, 1, 0, 0) + qsec,
            valid[:-1],
        ]
        for raw in malformed:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    dns.verify(raw, query, 512, 0)

    def test_error_question_literal_dot_does_not_spoof_labels(self):
        query = dns.query("r512-error.test", 5)
        label = b"r512-error.test"
        changed = bytes([len(label)]) + label + b"\0" + struct.pack("!HH", 16, 1)
        raw = query[:2] + struct.pack("!5H", 0x8182, 1, 0, 0, 0) + changed
        with self.assertRaisesRegex(ValueError, "question mismatch"):
            dns.verify(raw, query, 512, 0)


class LiveScenarioTests(unittest.TestCase):
    def test_entire_request_lifecycle_has_one_deadline(self):
        args = types.SimpleNamespace(target="unused", source="unused", port=53053)
        for phase in ("connect", "write", "read", "close"):
            with self.subTest(phase=phase):
                class Writer:
                    closed = False
                    def write(self, _raw):
                        pass
                    async def drain(self):
                        if phase == "write":
                            await asyncio.Event().wait()
                    def close(self):
                        self.closed = True
                    async def wait_closed(self):
                        if phase == "close":
                            await asyncio.Event().wait()
                writer = Writer()
                async def open_connection(*_args, **_kwargs):
                    if phase == "connect":
                        await asyncio.Event().wait()
                    return object(), writer
                async def receive(_reader):
                    if phase == "read":
                        await asyncio.Event().wait()
                    return b"response"
                started = time.monotonic()
                with mock.patch.object(live.asyncio, "open_connection", open_connection), mock.patch.object(dns, "receive", receive):
                    with self.assertRaises(asyncio.TimeoutError):
                        asyncio.run(live.raw_request(args, dns.query("r512-timeout.test", 1), timeout=.02))
                self.assertLess(time.monotonic() - started, .5)
                self.assertEqual(writer.closed, phase != "connect")

    def test_fixture_reverses_four_queries_without_timing_assumptions(self):
        queries = [dns.query(f"r512-order-{n}.dns-size.invalid", n) for n in range(100, 104)]
        source = b"".join(dns.frame(q) for q in queries)
        emitted = []

        async def scenario(mode_file):
            response_written = asyncio.Event()
            class Reader:
                data = source
                async def readexactly(self, size):
                    if not self.data:
                        await response_written.wait()
                        raise asyncio.IncompleteReadError(b"", size)
                    result, self.data = self.data[:size], self.data[size:]
                    return result
            class Writer:
                data = b""
                def get_extra_info(self, _name):
                    return ("198.18.32.42", 12345)
                def write(self, raw):
                    self.data += raw
                    response_written.set()
                async def drain(self):
                    pass
                def close(self):
                    response_written.set()
            writer = Writer()
            class Server:
                def close(self):
                    pass
                async def wait_closed(self):
                    pass
            async def start_server(handle, *_args, **_kwargs):
                asyncio.create_task(handle(Reader(), writer))
                return Server()
            args = types.SimpleNamespace(duration=.05, bind="unused", ports=[12345], allow=["198.18.32.42"], mode_file=str(mode_file), stats_file=None)
            with mock.patch.object(dns.asyncio, "start_server", start_server), mock.patch.object(dns, "emit", lambda event, **data: emitted.append(dict(event=event, **data))):
                await dns.serve(args)
            return writer.data

        with tempfile.TemporaryDirectory() as temporary:
            mode = Path(temporary) / "mode.json"
            mode.write_text(json.dumps({"mode": "blackhole", "ports": {"12345": {"mode": "healthy", "reorder": True}}}))
            raw = asyncio.run(scenario(mode))
        order = []
        while raw:
            size = struct.unpack_from("!H", raw)[0]
            response, raw = raw[2:2+size], raw[2+size:]
            ident = struct.unpack_from("!H", response)[0]
            self.assertEqual(dns.verify(response, queries[ident-100], 512, 0), 0)
            order.append(ident)
        self.assertEqual(order, [103, 102, 101, 100])
        final = next(event for event in emitted if event["event"] == "final")
        self.assertEqual(final["stats"]["responses"], 4)
        self.assertEqual(final["stats"].get("response_errors", 0), 0)
        self.assertEqual(final["ports"]["12345"]["accepted"], 1)
        self.assertEqual(final["ports"]["12345"]["queries"], 4)
        self.assertEqual(final["ports"]["12345"]["responses"], 4)
        self.assertEqual(final["ports"]["12345"]["active"], 0)


class ResilienceHarnessTests(unittest.TestCase):
    def args(self, mode_file):
        return types.SimpleNamespace(mode_file=str(mode_file), stats_file="unused", primary_port=15353,
                                     secondary_port=15354, scenario="primary_close")

    def test_original_mode_restored_after_scenario_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "mode.json"
            original = b'{"mode":"healthy", "ttl":27}\n'
            path.write_bytes(original)
            scenarios = resilience.Scenarios(self.args(path))
            async def snapshot():
                return {"ports": {}}
            async def failure(_mode):
                scenarios.set_mode(primary="close")
                raise AssertionError("injected scenario failure")
            scenarios.snapshot, scenarios.primary_failure = snapshot, failure
            with mock.patch.object(dns, "emit", lambda *_args, **_kwargs: None):
                with self.assertRaisesRegex(AssertionError, "injected"):
                    asyncio.run(scenarios.run())
            self.assertEqual(path.read_bytes(), original)

    def test_absent_mode_restored_after_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "mode.json"
            scenarios = resilience.Scenarios(self.args(path))
            scenarios.set_mode(primary="blackhole")
            async def blocked_snapshot():
                await asyncio.Event().wait()
            scenarios.snapshot = blocked_snapshot
            async def cancel():
                await asyncio.wait_for(scenarios.run(), .01)
            with mock.patch.object(dns, "emit", lambda *_args, **_kwargs: None):
                with self.assertRaises(asyncio.TimeoutError):
                    asyncio.run(cancel())
            self.assertFalse(path.exists())


class StageAccountingTests(unittest.TestCase):
    def stage(self, max_inflight=1024, require_success=False):
        args = types.SimpleNamespace(rate=100, duration=.05, label="offline", size=512,
                                     timeout=1, cache=False, max_inflight=max_inflight,
                                     require_success=require_success)
        events = []

        async def request(_args, _name, ident):
            if ident == 1:
                return 2, b"fixture SERVFAIL"
            if ident == 2:
                raise asyncio.TimeoutError("fixture transport timeout")
            return 0, b"fixture NOERROR"

        with mock.patch.object(dns, "request", request), mock.patch.object(dns, "emit", lambda event, **data: events.append(dict(event=event, **data))):
            if require_success:
                with self.assertRaises(SystemExit):
                    asyncio.run(dns.stage(args))
            else:
                asyncio.run(dns.stage(args))
        return events[-1]

    def test_answer_codes_and_transport_errors_are_distinct(self):
        result = self.stage()
        self.assertEqual(result["planned"], 5)
        self.assertEqual(result["stats"]["started"], 5)
        self.assertEqual(result["stats"]["completed"], 5)
        self.assertEqual(result["stats"]["success"], 3)
        self.assertEqual(result["stats"]["rcode_2"], 1)
        self.assertEqual(result["errors"], {"TimeoutError": 1})
        self.assertIsNotNone(result["p95_ms"])
        self.assertEqual(result["stats"]["completed"], sum(result["errors"].values())
                         + result["stats"]["success"] + result["stats"]["rcode_2"])

    def test_capacity_drops_remain_visible(self):
        result = self.stage(max_inflight=0)
        self.assertEqual(result["stats"]["capacity_drops"], 5)
        self.assertEqual(result["stats"].get("started", 0), 0)
        self.assertIsNone(result["p95_ms"])
        self.assertEqual(result["planned"], result["stats"]["capacity_drops"])

    def test_require_success_rejects_servfail_and_transport_failures(self):
        result = self.stage(require_success=True)
        self.assertEqual(result["event"], "stage_result")
        self.assertLess(result["stats"]["success"], result["planned"])


class BuildTests(unittest.TestCase):
    def test_generated_bundle_has_explicit_config_and_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "relay.lua"
            result = subprocess.run([sys.executable, str(ROOT / "tools" / "build.py"),
                                     "--config", str(ROOT / "config" / "example.lua"),
                                     "--output", str(output)], check=True, text=True, capture_output=True)
            data = output.read_text(encoding="ascii")
            positions = [data.index(f'modules["{name}"] =') for name in ("dns_wire", "cache", "relay", "main")]
            self.assertEqual(positions, sorted(positions))
            self.assertIn("return modules.main.start(config, rt)", data)
            self.assertIn("sha256=", result.stdout)
            self.assertIn('listen_host = "127.0.0.1"', data)


if __name__ == "__main__":
    unittest.main()
