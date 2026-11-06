# iDeck native modules — status

This change adds an actual Objective-C++ module to the iDeck Xcode target.

- `NativeRuntimeDiagnostics.mm` queries the real Metal device and detects the
  availability of linked FEX, Wine, DXMT, D3D12 and launch entry points.
- `NativeRuntimeDiagnostics.h` provides a stable C ABI to Swift and other
  native components.
- `ideck_native_validate_pe` validates DOS and PE headers before attempting
  a Wine launch.
- The Swift runtime readiness check uses native capabilities rather than
  duplicating symbol detection.

These diagnostics do **not** emulate a CPU, implement Wine, translate D3D
or bypass iPadOS code-signing/JIT restrictions. Upstream Madeira's native
archives, Wine PE modules, D3D12 shader converter, native launch adapter and
Metal presentation integration still need to be built and linked.

The current upstream Madeira project already contains substantial Objective-C,
Objective-C++, C and C++ code. Reusing the source with its licence and pinned
forks is safer than inventing a second emulator. Rust and Java are not required.

GitHub-hosted macOS jobs remain subject to GitHub billing; a workflow cannot
override an account-level runner payment restriction.
