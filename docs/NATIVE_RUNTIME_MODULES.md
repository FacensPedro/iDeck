# iDeck native module boundaries

The files in `iDeck/NativeRuntime/` are actual C, C++, Objective-C and Objective-C++ sources registered in the Xcode project.

| Source | Responsibility |
| --- | --- |
| MadeiraRuntimeBridge.h/.mm | Stable adapter API and guarded runtime preparation; intentionally does not export the production launch ABI |
| FEXRuntime.cpp | Checks and invokes an already linked FEX initializer |
| WineServerBridge.m | Checks and invokes an already linked Wine server initializer |
| WineProcessBridge.mm | Checks and invokes an already linked Wine process entry point |
| DXMTBridge.mm | Detects the existing native DXMT presentation entry point |
| D3D12Bridge.cpp | Detects the existing Madeira D3D12 canary symbol |
| MetalRenderer.mm | Creates/releases an offscreen Metal texture owned by the caller |
| JITMemoryManager.c | Allocates memory as RW; attempts RX transition only when permitted by iPadOS |
| NativePerformance.h | Stable C ABI used by the host-side performance utilities and exposed to Swift |
| FEXExecutionScheduler.cpp | Bounded, opt-in host task scheduling; does not change FEX's internal JIT scheduler |
| GuestMemoryPool.cpp | Bounded reuse of ordinary heap blocks, never JIT or executable pages |
| MetalFrameOptimizer.mm | Configures a CAMetalLayer and avoids redundant drawable-size changes |
| RuntimePerformanceMonitor.mm | Lightweight, opt-in frame timing and automatic swapchain creation counters |
| NativePerformanceClock.cpp | Monotonic nanosecond timer for explicit duration measurements |
| scripts/build_native_runtime.sh | Checks macOS/Xcode and upstream Madeira source tree, refusing to fake runtime availability |

## Scope and limitations

These are *integration adapters*, not implementations of FEX, Wine, DXMT, or D3D12.
The production symbol `ideck_madeira_launch_v1` stays undefined until a complete,
verified in-process Madeira launch implementation exists. The current adapter
`ideck_runtime_launch` does not support argument forwarding, and will fail
explicitly rather than silently dropping guest arguments. DXMT and D3D12
functions merely detect upstream linkage; the renderer allocates an offscreen
texture, not a Wine swapchain/presentation pipeline.

Upstream source/build references: https://github.com/willfaust/Madeira .
Its fork-specific toolchain, ARM64EC PE modules, static archives and shader
conversion components must be compiled separately according to upstream
instructions, then linked and packaged. Do not treat cloning sources as a
completed build.

To run the source-tree preflight on a Mac, use
`bash scripts/build_native_runtime.sh`. To create an explicitly
interface-only build after preflight, use
`IDECK_BUILD_INTERFACE_ONLY=1 bash scripts/build_native_runtime.sh`.

A functional iOS IPA and a successful on-device Windows game test are **not**
implied by these files. GitHub-hosted build jobs are subject to repository
billing and runner availability. Rust is optional, not required.

For module ownership rules, test commands, and benchmark requirements, see [Native Performance Foundation](NATIVE_PERFORMANCE.md). These utilities do not independently improve FPS or establish Windows game compatibility.
