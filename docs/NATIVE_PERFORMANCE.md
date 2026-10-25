# Native Performance Foundation

The performance modules in `iDeck/NativeRuntime/` provide small, independently testable building blocks for the iDeck host. They do not implement an x86 emulator, improve JIT permissions, or replace Madeira's FEX/Wine/DXMT backends.

## Modules

| Module | API | Purpose | Integration status |
| --- | --- | --- | --- |
| `FEXExecutionScheduler.cpp` | `ideck_scheduler_*` | Bounded background work queue with a fixed worker count, completion barrier and graceful shutdown | Opt-in; does not replace the internal FEX scheduler |
| `GuestMemoryPool.cpp` | `ideck_memory_pool_*` | Thread-safe, capped reuse of ordinary host heap blocks | Opt-in; not used for executable or JIT memory |
| `MetalFrameOptimizer.mm` | `ideck_metal_frame_*` | Metal layer setup and pixel-size updates without redundant resize assignments | Used by `MetalSwapchain.mm`; not an FPS guarantee |
| `RuntimePerformanceMonitor.mm` | `ideck_performance_*` | Lightweight, atomic frame-time and swapchain creation counters | Reset during native session preparation; swapchains counted automatically |
| `NativePerformanceClock.cpp` | `ideck_performance_now_ns`, `ideck_performance_record_interval` | Monotonic nanosecond clock and explicit frame-interval reporting | Opt-in; frame durations require explicit instrumentation |
| `NativePerformance.h` | C ABI | Public interface callable from Swift and C/Objective-C/C++ | Imported by `iDeck-Bridging-Header.h` |
| `NativeMemoryManager.cpp` | `ideck_native_memory_*` | Bounded scratch-memory allocation and cache reclamation under pressure | Initialized at app launch; only used by explicit scratch clients |
| `NativeMemoryPressure.mm` | UIKit notifications | Reacts to app memory warnings and background/foreground transitions | Registered once during app launch |

## Behavioral contract

- A scheduler owns a bounded queue with 1–16 workers. Submission fails immediately when the queue is full. `wait_idle` and `destroy` must be called by the owner, not from a scheduler callback; callbacks must keep their contexts alive until completion.
- The memory pool returns ordinary heap memory (never executable memory) and caches released allocations up to its configured byte limit. Callers must return pointers exactly once. Destroying the pool invalidates every outstanding pointer; external synchronization is required if threads are still using it.
- The Metal helper accepts a `CAMetalLayer` pointer. It does not submit frames, intercept Wine/DXMT drawing, or create Metal shader pipelines. Layer property updates should be performed on the UI/rendering coordination thread.
- Frame count and frame time are incremented only by explicit `record_frame` or `record_interval` calls; the swapchain module records successful swapchain creation. Do not interpret empty frame data as a measured zero FPS.
- Telemetry snapshots are lightweight and eventually consistent across fields while recording continues. Values are reset when a new runtime preparation starts.

## Host tests

On macOS with the Xcode Command Line Tools:

```sh
xcrun clang++ -std=c++20 -O2 -pthread -x c++ \
  tests/host/NativePerformanceTests.cpp \
  iDeck/NativeRuntime/FEXExecutionScheduler.cpp \
  iDeck/NativeRuntime/GuestMemoryPool.cpp \
  iDeck/NativeRuntime/NativePerformanceClock.cpp \
  iDeck/NativeRuntime/RuntimePerformanceMonitor.mm \
  -o /tmp/ideck-native-performance-tests

/tmp/ideck-native-performance-tests
```

The iOS Build GitHub Actions workflow runs the same host tests and validates that the new source files appear exactly once in the iDeck Xcode target.

## Future profiling

A meaningful optimization should first capture frame-time percentiles, allocation peaks, memory pressure, and processor usage on a physical iPad. Compare the same game scene before and after each change. These modules alone do not establish performance improvements or Windows-game compatibility.
\nSee [iOS memory management](IOS_MEMORY_MANAGEMENT.md) for the scratch-buffer budget, UIKit pressure callbacks and limitations; ordinary guest/JIT memory remains outside this pool.\n