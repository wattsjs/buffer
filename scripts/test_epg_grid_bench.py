import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("epg_grid_bench", Path(__file__).with_name("bench-epg-grid.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class EPGGridBenchmarkGateTests(unittest.TestCase):
    def report(self, calls):
        return {"fixture": "epg-appkit-horizontal-100x-672-blocks-v1", "rows": 1000,
                "visible_rows": 9, "overlay_entries": 21, "samples_ms": [2.0] * 7,
                "provider_calls": [calls] * 7}

    def test_rejects_missing_rows_and_viewport_mismatch(self):
        for field, value in (("visible_rows", 0), ("overlay_entries", 0), ("rows", 0), ("visible_rows", 8)):
            after = self.report(0)
            after[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                bench.verify_scroll(self.report(21), after)

    def test_rejects_late_cache_rebuild(self):
        after = self.report(0)
        after["provider_calls"][-1] = 1
        with self.assertRaises(ValueError):
            bench.verify_scroll(self.report(21), after)

    def test_rejects_invalid_or_incomplete_samples(self):
        for samples in ([1.0], [0.0] * 7, [float("nan")] * 7, [float("inf")] * 7):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                bench.sample_median(samples)

    def test_accepts_matching_viewport_and_reused_rows(self):
        bench.verify_scroll(self.report(21), self.report(0))


if __name__ == "__main__":
    unittest.main()
