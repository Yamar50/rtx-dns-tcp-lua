"""Check measurement windows and that incomplete/error runs cannot pass."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("summarize_run", Path(__file__).resolve().parents[1] / "tools/summarize_run.py")
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class MeasurementTests(unittest.TestCase):
    def test_cpu_parser_excludes_partial_sample_and_uses_five_seconds(self):
        samples = summary.cpu_samples("SAMPLE 100000\nCPU: 12%(5sec) 99%(1min) メモリ: 42% used\nCPU0: 24%(5sec)\nCPU1: 0%(5sec)\nSAMPLE 105000\nCPU: 10%(5sec)\n")
        self.assertEqual(samples, [dict(epoch=100, CPU=12, CPU0=24, CPU1=0, memory=42)])

    def test_window_omits_startup_and_post_load_samples(self):
        start = dict(event="stage_start", label="run", epoch=100, duration=10, rate=1, planned=10, size=512)
        end = dict(event="stage_result", label="run", stats={"success": 10}, errors={}, p50_ms=1, p95_ms=2, p99_ms=3)
        samples = [dict(epoch=t, CPU=load, CPU0=load * 2, CPU1=0, memory=42)
                   for t, load in [(100, 40), (104, 35), (105, 10), (110, 12), (111, 30)]]
        result = summary.summarize([start, end], samples)["completed"][0]
        self.assertEqual(result["cpu_samples"], 2)
        self.assertEqual(result["cpu_5sec_percent"]["CPU0"], dict(min=20, max=24, mean=22))
        self.assertTrue(result["all_success"])
        end["errors"] = {"TimeoutError": 1}
        self.assertFalse(summary.summarize([start, end], samples)["completed"][0]["all_success"])

    def test_unfinished_run_is_not_success(self):
        start = dict(event="stage_start", label="pending", epoch=100, duration=3600, rate=100, planned=360000, size=512)
        result = summary.summarize([start], [])
        self.assertEqual(result["completed"], [])
        self.assertEqual(result["unfinished"], [start])


if __name__ == "__main__":
    unittest.main()
