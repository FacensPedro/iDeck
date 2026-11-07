# Optimization plan — Phase 1: diagnostics and baseline

Status: **PENDING VALIDATION**. The instrumentation is in place and CI-verified;
the baseline numbers must be recorded on a physical iPad (at least five runs
per scenario) before Phase 2 starts. No percentage gain is claimed anywhere.

## What is measured

Settings › Bugs & logs › **Record benchmarks** (off by default). Each game
session and each Steam or Epic install writes one JSON report to
Files › iDeck › iDeck › Benchmarks.

| Metric | Source | Notes |
|---|---|---|
| FPS average | Madeira's present counter (`madeira_get_present_count`) | From the first frame to the end of the session |
| Frame time P50 / P95 / P99 / max | Same counter, polled every 4 ms in C++ | Resolution 4 ms; needs ≥ 30 frames; several presents in one poll share its interval |
| CPU seconds, CPU % average and peak | `getrusage(RUSAGE_SELF)`, once a second | Whole process: Wine, FEX, DXMT and iDeck run in it |
| RAM peak and average | `task_info(TASK_VM_INFO).phys_footprint` | The figure iOS counts against the memory limit |
| Metal memory peak | `MTLDevice.currentAllocatedSize` | |
| Thermal state time | `ProcessInfo.thermalState`, per second | Seconds in nominal / fair / serious / critical |
| Low Power Mode time | `ProcessInfo.isLowPowerModeEnabled` | |
| Wine start, first frame | Status milestones, recorder | `wine_started`, `first_frame`, `running` |
| Install time, MB/s, CPU-seconds per GiB | Install session + installed bytes | Steam and Epic |
| Decrypt / decompress / write: calls, bytes, seconds, MB/s | C counters around `ideck_steam_decrypt_chunk`, `chunk_zip_decode`, `lzma_shim_decode`, `zstd_safe_decompress`, Epic `inflateWindow`, `ideck_steam_write_chunk` | Two clock reads and three relaxed atomic adds per call |
| Device, iOS, app build, source commit, runtime settings | `environment` and `settings` in each report | `sourceCommit` is stamped into the IPA by `scripts/stamp_ideck_runtime_profile.py` |

### Not available (listed in every report under `unavailable`)

- **GPU time per frame**: DXMT and madeira-d3d12 expose no per-frame GPU timestamps to iDeck.
- **Energy**: iOS gives an app no per-app power reading.
- **Temperature in °C**: iOS reports only the thermal state.
- **Unexpected terminations**: a jetsam kill ends the process before a report can be written; the missing report and the app log's last `[status]` line are the evidence.

## Comparing runs

```
python3 scripts/benchmark_report.py summary  BASELINE_DIR
python3 scripts/benchmark_report.py compare  BASELINE_DIR CANDIDATE_DIR
```

Scenarios are grouped by kind, label (game or install), device and iOS
version; only sessions that ended normally count. A scenario with fewer than
five runs on either side is **NOT TESTED**, never PASSED. `compare` checks the
plan's targets (install CPU-s/GiB −20 %, install RAM −15 %, install time
≤ +5 %, download ≥ 95 %, emulation CPU −15 %, emulation RAM −10 %, FPS ≥ 95 %,
P95 ≤ +5 %, startup −10 %).

## Recording the baseline (on the iPad)

1. Install the IPA built from the commit to measure; keep *Detailed diagnostics* off.
2. Turn on *Record benchmarks*.
3. Per game: launch, play the same fixed scene for the same time, close. Repeat five times, with the device at a similar temperature (wait for nominal between runs).
4. Per install: uninstall, install the same game five times on the same network.
5. Copy the Benchmarks folder from Files and run `summary`.

## Code analysis: candidate bottlenecks for later phases

Findings from reading the code. They are hypotheses until the baseline shows
where the time actually goes.

### Installs (Phase 2)
- `ideck_steam_write_chunk` opens, `fstat`s and closes the target file for **every chunk** (`SteamDiskIO.c`). Large games write hundreds of thousands of chunks into a few files; keeping descriptors open per file would remove most `open`/`close` calls.
- Each Steam chunk crosses Swift `Data` several times (download → decrypt output → decompress output → write); the C stages could share one reusable buffer per worker.
- Steam concurrency is fixed by thermal state (8 by default, up to 64 with *Unlimited download speed*); decompression has no separate limit from downloading.
- Progress updates are already throttled to 4 per second (Steam and Epic): not a bottleneck.
- Epic keeps up to 256 MB of chunks in memory before spilling (`memoryBudget`), a likely contributor to the install RAM peak.

### Emulation (Phases 3–6)
- Madeira's quiet / lean diagnostics are on by default since PR #134 (no PC sampler, no thread-suspending profilers): the baseline must be taken with them on, as shipped.
- During a game, `GameSessionView` re-attaches and re-lays out the Metal viewport **every second** while the status is *Running* (`WindowsRendererView.refreshNativeDisplay`), not only until the first frame.
- The in-game metrics timer samples once a second; the benchmark recorder adds one thread polling an atomic counter every 4 ms (only while recording).
- The Wine JIT pool now matches Madeira (896 MiB on 6 GB+ devices, PR #137); its size is part of each report.

### Polling loops (busy waiting)
- `SteamCMSession.ensureConnected` polls every 100 ms (up to 20 s) while another connect is in progress.
- `SteamOwnedGamesModel.resumeAfterBackground` polls every 100 ms (up to 5 s).
- `ideck_wineprocess_start` polls `is_running` every 10 ms (up to 0.5 s).
- Epic's 5-second session timer runs only while a download is active.
None of these runs during steady gameplay.

## Phase 1 status against its criteria

| Criterion | Status |
|---|---|
| Baseline for 100 % of the essential metrics that exist | PENDING — instrumentation done, numbers need the iPad |
| ≥ 5 runs per scenario | PENDING — enforced by `benchmark_report.py` |
| Device, OS, runtime configuration and commit recorded | PASSED — in every report |
| Initial results available for comparison | PENDING — after the device runs |
| Unavailable metrics identified, not invented | PASSED — listed above and in each report |
