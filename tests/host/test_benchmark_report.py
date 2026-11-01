import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("benchmark_report", ROOT / "scripts/benchmark_report.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def report(kind, cpu, memory, fps=None, p95=None, wine=None, seconds=100.0, label="Cuphead", outcome="closed", bytes_=0):
    metrics = {"kind": kind, "label": label, "cpuSeconds": cpu, "memoryPeakMB": memory, "durationSeconds": seconds,
               "fpsAverage": fps, "frameTimeMs": {"p50": 16.6, "p95": p95, "p99": 33.0, "max": 50.0} if p95 else None,
               "stages": {}, "installBytes": bytes_}
    derived = {}
    if wine is not None:
        derived["wineStartSeconds"] = wine
    if bytes_:
        derived["installMegabytesPerSecond"] = bytes_ / 1048576 / seconds
        derived["cpuSecondsPerGiB"] = cpu / (bytes_ / 1073741824)
    return {"schema": 1, "outcome": outcome, "environment": {"device": "iPad16,3", "systemVersion": "27.0.1"},
            "metrics": metrics, "derived": derived}


class BenchmarkReportTests(unittest.TestCase):
    def write(self, folder, reports):
        for i, data in enumerate(reports):
            (folder / f"r{i}.json").write_text(json.dumps(data))

    def compare(self, base, cand):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            self.write(pathlib.Path(a), base)
            self.write(pathlib.Path(b), cand)
            return {r["target"]: r for r in bench.compare(pathlib.Path(a), pathlib.Path(b))}

    def test_targets_pass_and_fail_by_direction(self):
        base = [report("game", 100, 1000, fps=50, p95=20, wine=10) for _ in range(5)]
        cand = [report("game", 80, 950, fps=49, p95=22, wine=8) for _ in range(5)]
        rows = self.compare(base, cand)
        self.assertEqual(rows["Emulation CPU (same workload): -15% or better"]["status"], "PASSED")   # -20%
        self.assertEqual(rows["Emulation RAM peak: -10% or better"]["status"], "FAILED")              # -5%
        self.assertEqual(rows["Average FPS: at least 95% of baseline"]["status"], "PASSED")           # -2%
        self.assertEqual(rows["P95 frame time: at most +5%"]["status"], "FAILED")                     # +10%
        self.assertEqual(rows["Startup time: -10% or better"]["status"], "PASSED")                    # -20%

    def test_fewer_than_five_runs_is_not_tested(self):
        rows = self.compare([report("game", 100, 1000, fps=50)] * 4, [report("game", 50, 500, fps=60)] * 5)
        self.assertTrue(all(r["status"] == "NOT TESTED" for r in rows.values()))

    def test_failed_sessions_and_missing_metrics_are_not_counted(self):
        base = [report("game", 100, 1000, fps=50) for _ in range(5)] + [report("game", 1, 1, outcome="failed: x")]
        cand = [report("game", 90, 900, fps=50) for _ in range(5)]
        rows = self.compare(base, cand)
        self.assertEqual(rows["P95 frame time: at most +5%"]["status"], "NOT TESTED")
        self.assertIn("100.00 -> 90.00", rows["Emulation CPU (same workload): -15% or better"]["detail"])

    def test_install_targets(self):
        gib = 1073741824
        base = [report("install", 200, 800, seconds=100, bytes_=gib, label="Steam: X") for _ in range(5)]
        cand = [report("install", 150, 700, seconds=104, bytes_=gib, label="Steam: X") for _ in range(5)]
        rows = self.compare(base, cand)
        self.assertEqual(rows["CPU-seconds per GiB installed: -20% or better"]["status"], "PASSED")  # -25%
        self.assertEqual(rows["Install RAM peak: -15% or better"]["status"], "FAILED")               # -12.5%
        self.assertEqual(rows["Install time: at most +5%"]["status"], "PASSED")                      # +4%


class BenchmarkInstrumentationTests(unittest.TestCase):
    def test_recorder_is_cpp_behind_objective_cpp(self):
        self.assertIn('#include "BenchmarkRecorder.hpp"', (ROOT / "iDeck/BenchmarkBridge.mm").read_text())
        self.assertIn('#import "BenchmarkBridge.h"', (ROOT / "iDeck/iDeck-Bridging-Header.h").read_text())
        self.assertIn("constexpr uint64_t kFramePollNs = 4'000'000;", (ROOT / "iDeck/BenchmarkRecorder.cpp").read_text())

    def test_pipeline_stages_are_timed(self):
        codecs = (ROOT / "iDeck/SteamChunkCodecs.c").read_text()
        for name in ("chunk_zip_decode", "lzma_shim_decode", "zstd_safe_decompress"):
            self.assertIn(f"{name}_untimed(", codecs)
        self.assertIn("IDECK_STAGE_WRITE", (ROOT / "iDeck/SteamDiskIO.c").read_text())
        self.assertIn("IDECK_STAGE_DECRYPT", (ROOT / "iDeck/SteamNativeCore.c").read_text())
        self.assertIn("IDECK_STAGE_DECOMPRESS", (ROOT / "iDeck/EpicChunkCodec.cpp").read_text())

    def test_sessions_are_recorded_from_launch_and_install(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn('BenchmarkSession.mark("wine_started")', coordinator)
        self.assertIn('BenchmarkSession.finish(kind: "game", outcome: "closed")', coordinator)
        self.assertIn('BenchmarkSession.begin(kind: "install"', (ROOT / "iDeck/SteamManager.swift").read_text())
        self.assertIn('BenchmarkSession.begin(kind: "install"', (ROOT / "iDeck/EpicLibrary.swift").read_text())

    def test_reports_name_the_commit(self):
        self.assertIn('"sourceCommit": source_commit()', (ROOT / "scripts/stamp_ideck_runtime_profile.py").read_text())


if __name__ == "__main__":
    unittest.main()
