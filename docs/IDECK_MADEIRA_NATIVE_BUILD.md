# iDeck / Madeira native runtime: integration contract

Status: source checkout and the app-side ABI are implemented. Native emulator
binaries, linker integration and device testing are **not implemented**.
No Windows games are claimed to run in this branch.

## Upstream reference

Use Madeira pinned to commit `279fd0f83170425db002fe25d6bd62f6355f497d`
and its submodule gitlinks (FEX, Wine, DXMT). Do **not** silently substitute
desktop Linux versions, generic box64, stock Wine or unpatched DXMT.

```bash
bash scripts/fetch_madeira_sources.sh
```

Upstream reference files:

- `vendor/Madeira/app/Madeira/FEXBridge.mm` / `FEXBridge.h`: in-process
  FEX initialization, JIT allocation.
- `vendor/Madeira/app/Madeira/WineServerBridge.m` and
  `WineProcessBridge.m`: wineserver thread, Wine runtime and process startup.
- `vendor/Madeira/build/fex-ios/build.sh`: native FEX archives.
- `vendor/Madeira/build/ntdll-unix/build.sh`: iOS Wine unix libraries.
- `vendor/Madeira/build/dxmt-ios/build.sh`: native DXMT/Metal.
- `vendor/Madeira/build/madeira-d3d12/build-pe.sh`: ARM64EC D3D12 DLL.
- `vendor/Madeira/docs/BUILDING.md`: exact tools and missing licensed
  prerequisites, including Apple Metal Shader Converter.

The upstream build scripts run on **macOS with Xcode**. Downloading source
files under Linux or Windows does not provide the Apple iOS SDK or a signed
device-testable runtime. Follow the upstream license and third-party notices.

## Launcher

`iDeck/WindowsEnvironment.swift` never invokes
`posix_spawn(box64, wine64, exe)`. Its `BoxTranslator` checks a linked
`ideck_madeira_launch_v1` symbol and calls it on a background queue.

The function has the exact C declaration in `iDeck/NativeRuntimeABI.h`.
It receives UTF-8 executable path, Wine prefix and JSON parameters, and
returns after the Windows guest session has started. Session exit handling
requires separate integration with Wine's native callbacks. A compatible implementation
needs to invoke the **real** upstream in-process FEX/Wine/wineserver machinery
and must use DXMT/D3D12 resources for graphics.

No such function definition is included yet. A symbol-only stub is not
equivalent to an emulator and must not be added to make the readiness check
pass.

## When the native runtime is available

1. Build upstream FEX, Wine ARM64EC and Wine Unix, DXMT and D3D12 with the
   exact Madeira forks, dependencies, tools and applicable licences.
2. Add the actual native bridge implementation and its archives, frameworks,
   exported C symbols and Metal resources to the iDeck Xcode target. The
   implementation must satisfy `ideck_madeira_launch_v1`, not an external
   process launch.
3. Stage PE DLLs in `iDeck.app/MadeiraRuntime/aarch64-windows/`
   (`d3d11.dll`, `dxgi.dll`), and in
   `iDeck.app/MadeiraRuntime/arm64ec-windows/` (`d3d12.dll`,
   `d3d12core.dll`). Supply `MadeiraRuntime/d3d12/libmetalirconverter.dylib`
   under its applicable licence and code-signing rules.
4. Run `IDECK_REQUIRE_MADEIRA=1 bash scripts/build_ipa.sh` on a working
   macOS/Xcode host, or choose **Require Madeira runtime** in the GitHub
   workflow dispatch. Both invoke `scripts/verify_madeira_bundle.py` before
   packaging. On absent files or symbols, the build fails instead of making
   an IPA claiming to run Windows.
5. Install a properly signed IPA and verify JIT, a Win32 test app, x86_64
   translation, Direct3D 9/11/12, controller/mouse, saves and clean shutdown.

## Runtime marker contract

Only the verifier creates `MadeiraRuntimeManifest.plist` in the built
app. The manifest is absent in an interface-only build. It requires the
FEX/Wine API symbols, DXMT present counter, D3D12 canary and the real
`ideck_madeira_launch_v1` linker export plus packaged PE/shader libraries.

This build-time check detects missing artifacts; it cannot certify that a
runtime is bug-free or usable on iPadOS. That needs device tests.

## GitHub Actions billing

The user's workflow failed before its first step. GitHub reported:
"The job was not started because recent account payments have failed or
your spending limit needs to be increased."

The error is an account billing/spending restriction, **not** a compiler
failure and not a Copilot quota issue. Code or workflow changes cannot
override GitHub account billing restrictions. The account owner must
resolve the payment/budget setting, or provide an authorized macOS runner
outside the blocked GitHub-hosted allocation.

Until then there is no verified macOS build and no runnable runtime IPA.
