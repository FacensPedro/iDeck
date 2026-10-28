# iDeck native Windows runtime: audit and JIT pool selection (2026-10-29)

## Current status

The repository can build an interface-only IPA. This is **not** proof that an actual Windows guest boots. Native runtime builds must pass `scripts/verify_madeira_bundle.py --require`, be signed correctly and be tested on-device with the Madeira-compatible JIT debugger.

## Automatic Wine JIT pool sizing

The native `FEXRuntime.cpp` now uses `hw.memsize` to choose the first Wine RX/RW pool size: 96 MiB below 3 GiB, 128 MiB at 3 GiB, 192 MiB at 4 GiB, 256 MiB at 6 GiB, and 384 MiB at 8 GiB or more. If that attempt fails, it tries smaller supported pool sizes, ending at 64 MiB. FEX has a separate upstream pool.

An optional environment override `IDECK_WINE_JIT_MIB` may be set **before the Wine runtime is prepared** to one of 64, 96, 128, 192, 256, or 384. Unsupported values are ignored. This override is intended for compatible native runtime builds and is not yet exposed through the SwiftUI Settings screen. Once a pool is allocated, changing the value does not resize it until the process restarts.

This is virtual executable memory, **not** a change to the iOS physical-memory limit. Memory heuristics do not replace debugger protocol, MAP/JIT permission or executable region checks.

## Verified source-level gaps

- `scripts/verify_madeira_bundle.py` explicitly permits interface-only packaging when `--require` is omitted. Release CI must enable native verification before presenting a Windows-emulation-capable IPA.
- The bundle verifier requires PE DLL payloads in both the app root and `MadeiraRuntime` directories, the native symbols, Wine locale, prefix template, shader converter, D3D12 fixtures, HTTPS certificate bundle and licensing directories. A missing artifact prevents native verification; mere presence does not guarantee correctness.
- On ARM64EC, the patched Wine native source must be **rebuilt**, not only included as a diff. Validate the Mach slowpath with real StikDebug/FEX/Wine execution.
- `ideck_fex_initialize` requires a live compatible debugger for initial BRK-based JIT allocation. A debugger that detaches after toggling JIT may be insufficient.
- `ideck_runtime_launch` rejects 32-bit Windows applications without the full WoW64 i386/ARM64 library farm. Ensure it is included when WoW64 is promised.
- GitHub Actions tests and an interface build alone cannot validate GPU rendering, controller input, Wine process lifetime or native ARM64EC translation on an iPad.

## Swift migration

At this revision, 52 of 232 versioned files have a `.swift` suffix (including host tests), or 22.4% of all versioned files. This fraction is **not** the share of implementation source code. SwiftUI views, application lifecycle and property-observation code should remain Swift. Low-level memory/JIT logic is already C/C++. Any future migration of utilities must preserve the Swift-facing ABI and Xcode target integration and run host tests.
