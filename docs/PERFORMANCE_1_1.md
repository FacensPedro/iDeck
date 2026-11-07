# iDeck 1.1: architecture and efficiency

No performance figures are claimed here: this work was done without an iPad,
so nothing in this document was measured on a device. The changes below are
verified by the host tests and the iOS build; their effect on CPU, RAM, FPS
and start-up time must be measured on a device (see "How to measure").

## What the analysis found

- Translation, Wine and rendering are done by Madeira's statically linked FEX,
  Wine ARM64EC, DXMT and D3D12 (fetched at the pinned commit by
  `scripts/fetch_madeira_sources.sh`). iDeck's own native code around them is
  small; most of what looked like an iDeck "performance layer" was never
  called.
- Unused native modules (nothing in Swift, Objective-C++ or the Madeira
  patches referenced them):
  - `FEXExecutionScheduler.cpp`: a worker-thread scheduler no code submitted to.
  - `NativeMemoryManager.cpp` + `GuestMemoryPool.cpp`: a memory pool whose
    allocation API was never called. Configure, trim and pressure calls ran
    on an empty pool, and its memory-warning observers duplicated
    `ResourceGovernor`, which does the real work.
  - `NativePerformance.cpp`: frame counters never recorded (the session screen
    reads Madeira's `madeira_get_present_count`).
  - Most of `MadeiraPlatform.mm` / `MadeiraCore.cpp`: an offscreen Metal
    renderer, a swapchain wrapper, layer helpers, a shader-library probe, an
    audio-session helper and raw RW→RX JIT helpers (`mprotect PROT_EXEC`),
    none of them called. Madeira's DXMT owns the swapchain and its JIT
    allocator owns executable memory.
- Per-second work in the game session:
  - `GameRuntimeMetrics` set five `@Published` values every second, so
    SwiftUI rebuilt the whole session view (toolbar, overlays, touch layers)
    every second for the whole game, also for values not on screen.
  - Every sample and every viewport layout looked up Madeira symbols with
    `dlsym(RTLD_DEFAULT, …)`, a search through all loaded images, up to seven
    times per layout.
- The 5-second JIT probe (sysctl, code-signing status, JIT snapshot) kept
  running during games, where JIT cannot change.
- iRelay transfers (SHA-1 checks, file writes) ran at `.userInitiated`, the
  same class as interactive work, while a game was playing.

## What 1.1 changes

| Area | Change | Expected effect (to be measured) |
| --- | --- | --- |
| Madeira Core | Removed the unused scheduler, memory pool/manager, performance counters, renderer/swapchain/layer helpers, audio helper and RX JIT helpers. `MadeiraPlatform.mm` keeps Metal/DXMT/D3D12 availability and the end of session | Smaller binary and code; no RX-capable code in iDeck's own sources |
| Memory | One memory-pressure handler (`ResourceGovernor`); the duplicate native observers are gone | Less work per warning; same cache release |
| Runtime Manager | `NativeSymbol` resolves each Madeira symbol once | No repeated `dlsym` on per-frame-layout and per-second paths |
| Session UI | `GameRuntimeMetrics` publishes only visible values, only on change; FPS/CPU/GPU memory measured only with the overlay on; the clock stops publishing once the game is shown | The session view is no longer rebuilt every second during play |
| JIT | The JIT probe pauses while a Wine game runs | No sysctl/code-signing probe every 5 s during play |
| iRelay | Transfers run at `.utility` | Transfers yield CPU to the game |

Unchanged on purpose: FEX, Wine, DXMT, D3D12 and their settings; the 896 MB
default JIT pool; StikDebug; resolution, texture, shader and graphics settings;
Wine Mono, Wine Gecko and `cmd.exe`; x86, x64 and ARM64EC; Madeira Dock; all
stores; controllers. The FEX, Wine and DXMT sources are upstream Madeira and
are not modified without device measurements that show a gain.

## How to measure

Use the same game, resolution and graphics settings before (1.0.15) and after (1.1):

1. Settings › Bugs & logs › **Record benchmarks** on (writes a JSON report per
   session to Files › iDeck › Benchmarks).
2. Turn on the performance overlay (FPS, CPU, Metal memory) for the run.
3. Play the same scene for the same time on each version.
4. Compare the reports with `scripts/benchmark_report.py`.

Record start-up time to first frame, average/minimum FPS, CPU and memory
footprint (`[memory]` lines in the log).

## Pending on a device

- Native IPA build with GitHub Actions (manual iOS Build run, Require Madeira
  runtime on), then install and play: the interface IPA from pull requests
  contains no Windows runtime and proves nothing about games.
- The measurements above, before and after.
