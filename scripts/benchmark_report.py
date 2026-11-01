#!/usr/bin/env python3
"""Aggregate and compare iDeck benchmark reports (Phase 1 of the plan).

Reports are the JSON files iDeck writes to Files › iDeck › iDeck ›
Benchmarks when Settings › Bugs & logs › Record benchmarks is on.

  summary DIR            one row per scenario: median, mean, stdev, runs
  compare BASE CANDIDATE  per-metric change against the plan's targets

A scenario is (kind, label, device, system version). Fewer than five runs
of a scenario are reported as such, never as a pass. Metrics missing from
the reports are shown as NOT TESTED, not filled in.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys
from typing import Any, Callable

MIN_RUNS = 5

# metric name -> (extractor, unit, lower is better)
METRICS: dict[str, tuple[Callable[[dict], Any], str, bool]] = {
    "cpuSeconds": (lambda r: r["metrics"].get("cpuSeconds"), "s", True),
    "cpuPercentAverage": (lambda r: r["metrics"].get("cpuPercentAverage"), "%", True),
    "memoryPeakMB": (lambda r: r["metrics"].get("memoryPeakMB"), "MB", True),
    "metalPeakMB": (lambda r: r["metrics"].get("metalPeakMB"), "MB", True),
    "fpsAverage": (lambda r: r["metrics"].get("fpsAverage"), "fps", False),
    "frameTimeP50": (lambda r: (r["metrics"].get("frameTimeMs") or {}).get("p50"), "ms", True),
    "frameTimeP95": (lambda r: (r["metrics"].get("frameTimeMs") or {}).get("p95"), "ms", True),
    "frameTimeP99": (lambda r: (r["metrics"].get("frameTimeMs") or {}).get("p99"), "ms", True),
    "wineStartSeconds": (lambda r: r.get("derived", {}).get("wineStartSeconds"), "s", True),
    "firstFrameSeconds": (lambda r: r.get("derived", {}).get("firstFrameSeconds"), "s", True),
    "durationSeconds": (lambda r: r["metrics"].get("durationSeconds"), "s", True),
    "installMegabytesPerSecond": (lambda r: r.get("derived", {}).get("installMegabytesPerSecond"), "MB/s", False),
    "cpuSecondsPerGiB": (lambda r: r.get("derived", {}).get("cpuSecondsPerGiB"), "s/GiB", True),
    "decompressMBps": (lambda r: r["metrics"].get("stages", {}).get("decompress", {}).get("megabytesPerSecond"), "MB/s", False),
    "writeMBps": (lambda r: r["metrics"].get("stages", {}).get("write", {}).get("megabytesPerSecond"), "MB/s", False),
    "decryptMBps": (lambda r: r["metrics"].get("stages", {}).get("decrypt", {}).get("megabytesPerSecond"), "MB/s", False),
}

# The plan's targets: metric -> (kind, required change in %, wording).
# For lower-is-better metrics the change must be <= the limit; for the others >= it.
TARGETS: dict[str, tuple[str, float, str]] = {
    "cpuSecondsPerGiB": ("install", -20, "CPU-seconds per GiB installed: -20% or better"),
    "memoryPeakMB@install": ("install", -15, "Install RAM peak: -15% or better"),
    "durationSeconds@install": ("install", 5, "Install time: at most +5%"),
    "installMegabytesPerSecond": ("install", -5, "Download speed: at least 95% of baseline"),
    "cpuSeconds@game": ("game", -15, "Emulation CPU (same workload): -15% or better"),
    "memoryPeakMB@game": ("game", -10, "Emulation RAM peak: -10% or better"),
    "fpsAverage": ("game", -5, "Average FPS: at least 95% of baseline"),
    "frameTimeP95": ("game", 5, "P95 frame time: at most +5%"),
    "wineStartSeconds": ("game", -10, "Startup time: -10% or better"),
}


def load(folder: pathlib.Path) -> list[dict]:
    reports = []
    for path in sorted(folder.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            print(f"skipped unreadable {path.name}", file=sys.stderr)
            continue
        if data.get("schema") == 1 and isinstance(data.get("metrics"), dict):
            data["_file"] = path.name
            reports.append(data)
    return reports


def scenario(report: dict) -> tuple[str, str, str, str]:
    env = report.get("environment", {})
    return (report["metrics"].get("kind", "?"), report["metrics"].get("label", "?"),
            env.get("device", "?"), env.get("systemVersion", "?"))


def group(reports: list[dict]) -> dict[tuple, list[dict]]:
    groups: dict[tuple, list[dict]] = {}
    for report in reports:
        if report.get("outcome") in ("closed", "completed"):
            groups.setdefault(scenario(report), []).append(report)
    return groups


def stats(values: list[float]) -> dict[str, float] | None:
    values = [float(v) for v in values if isinstance(v, (int, float))]
    if not values:
        return None
    return {"runs": len(values), "median": statistics.median(values), "mean": statistics.fmean(values),
            "stdev": statistics.stdev(values) if len(values) > 1 else 0.0}


def summarize(reports: list[dict]) -> dict[tuple, dict[str, dict]]:
    return {key: {name: s for name, (get, _, _) in METRICS.items() if (s := stats([get(r) for r in runs]))}
            for key, runs in group(reports).items()}


def print_summary(folder: pathlib.Path) -> int:
    summary = summarize(load(folder))
    if not summary:
        print("No completed sessions in", folder)
        return 1
    for (kind, label, device, system), metrics in sorted(summary.items()):
        runs = max((m["runs"] for m in metrics.values()), default=0)
        flag = "" if runs >= MIN_RUNS else f"  [ONLY {runs} RUN(S): need {MIN_RUNS}]"
        print(f"\n{kind} | {label} | {device} iOS {system}{flag}")
        for name, s in metrics.items():
            unit = METRICS[name][1]
            print(f"  {name:28} median {s['median']:10.2f} {unit:6} mean {s['mean']:10.2f}  stdev {s['stdev']:8.2f}  n={s['runs']}")
    return 0


def compare(base_dir: pathlib.Path, candidate_dir: pathlib.Path) -> list[dict]:
    """One row per scenario and target: PASSED, FAILED or NOT TESTED."""
    base, cand = summarize(load(base_dir)), summarize(load(candidate_dir))
    rows = []
    for key in sorted(set(base) | set(cand)):
        for target, (kind, limit, wording) in TARGETS.items():
            if key[0] != kind:
                continue
            metric = target.split("@")[0]
            b, c = base.get(key, {}).get(metric), cand.get(key, {}).get(metric)
            row = {"scenario": " | ".join(key), "target": wording}
            if not b or not c or b["runs"] < MIN_RUNS or c["runs"] < MIN_RUNS or b["median"] == 0:
                row.update(status="NOT TESTED", detail=f"runs base={b['runs'] if b else 0} candidate={c['runs'] if c else 0}")
            else:
                change = (c["median"] - b["median"]) / abs(b["median"]) * 100
                # Lower-is-better metrics must not rise past the limit (a
                # negative limit asks for a drop); the others must not fall below it.
                passed = change <= limit if METRICS[metric][2] else change >= limit
                row.update(status="PASSED" if passed else "FAILED",
                           detail=f"{b['median']:.2f} -> {c['median']:.2f} {METRICS[metric][1]} ({change:+.1f}%)")
            rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("summary"); s.add_argument("folder", type=pathlib.Path)
    c = sub.add_parser("compare"); c.add_argument("baseline", type=pathlib.Path); c.add_argument("candidate", type=pathlib.Path)
    c.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()
    if args.command == "summary":
        return print_summary(args.folder)
    rows = compare(args.baseline, args.candidate)
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for row in rows:
            print(f"{row['status']:11} {row['target']:52} {row['scenario']}  {row['detail']}")
    return 1 if any(r["status"] == "FAILED" for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
