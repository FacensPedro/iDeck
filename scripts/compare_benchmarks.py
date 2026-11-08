#!/usr/bin/env python3
"""Compare iDeck benchmark reports across versions (regression check).

Input: the JSON files iDeck writes to Files > On My iPad > iDeck > iDeck >
Benchmarks when "Record benchmarks" is on (Bug Report screen). Run the SAME
game and scenario on each version, then:

    python3 scripts/compare_benchmarks.py report1.json report2.json ...
    python3 scripts/compare_benchmarks.py --dir path/to/Benchmarks

Output: one row per (game, version) with the median of its runs, and the
change against the oldest version of the same game. Lower is better for every
column except fps, crashes count as "failed" outcomes.
"""
import argparse
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

COLUMNS = [
    # (label, getter, higher_is_better)
    ("ram_peak_MB", lambda r: r["metrics"].get("memoryPeakMB"), False),
    ("ram_avg_MB", lambda r: r["metrics"].get("memoryAverageMB"), False),
    ("metal_peak_MB", lambda r: r["metrics"].get("metalPeakMB"), False),
    ("wine_start_s", lambda r: r.get("derived", {}).get("wineStartSeconds"), False),
    ("first_frame_s", lambda r: r.get("derived", {}).get("firstFrameSeconds"), False),
    ("fps_avg", lambda r: r["metrics"].get("fpsAverage"), True),
    ("frame_p95_ms", lambda r: (r["metrics"].get("frameTimeMs") or {}).get("p95"), False),
    ("frame_p99_ms", lambda r: (r["metrics"].get("frameTimeMs") or {}).get("p99"), False),
    ("cpu_avg_pct", lambda r: r["metrics"].get("cpuPercentAverage"), False),
]


def version_key(v):
    out = []
    for part in str(v).replace("(", ".").replace(")", "").split("."):
        out.append(int(part) if part.isdigit() else 0)
    return out


def number(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def load(paths):
    runs = []
    for p in paths:
        try:
            r = json.loads(Path(p).read_text())
        except (OSError, ValueError) as e:
            print(f"skip {p}: {e}", file=sys.stderr)
            continue
        if r.get("metrics", {}).get("kind") not in (None, "game"):
            continue
        env = r.get("environment", {})
        r["_game"] = r.get("metrics", {}).get("label") or "?"
        r["_version"] = f'{env.get("appVersion", "?")}({env.get("appBuild", "?")})'
        runs.append(r)
    return runs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--dir")
    args = ap.parse_args()
    paths = list(args.files)
    if args.dir:
        paths += sorted(str(p) for p in Path(args.dir).glob("game-*.json"))
    runs = load(paths)
    if not runs:
        print("no game reports found", file=sys.stderr)
        return 1
    groups = defaultdict(list)
    for r in runs:
        groups[(r["_game"], r["_version"])].append(r)
    games = sorted({g for g, _ in groups})
    header = ["game", "version", "runs", "failed"] + [c[0] for c in COLUMNS]
    print("\t".join(header))
    for game in games:
        versions = sorted((v for g, v in groups if g == game), key=version_key)
        base = None
        for v in versions:
            rs = groups[(game, v)]
            failed = sum(1 for r in rs if str(r.get("outcome", "")).startswith("failed"))
            row = [game, v, str(len(rs)), str(failed)]
            meds = {}
            for label, get, higher in COLUMNS:
                vals = [x for x in (number(get(r)) for r in rs) if x is not None]
                med = statistics.median(vals) if vals else None
                meds[label] = med
                cell = "-" if med is None else f"{med:.1f}"
                if base and med is not None and base.get(label):
                    delta = (med - base[label]) / base[label] * 100
                    worse = delta < 0 if higher else delta > 0
                    cell += f" ({delta:+.0f}%{'!' if worse and abs(delta) >= 5 else ''})"
                row.append(cell)
            if base is None:
                base = meds
            print("\t".join(row))
    print("\n'!' marks a regression of 5% or more against the game's oldest version.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
