# Madeira runtime integration status

## Current state

This branch improves the iDeck library and adds per-title settings, but it does **not** yet contain the complete Madeira runtime. Windows executables must not be considered runnable just because their files were downloaded.

The current app still lacks the native, in-process runtime bridge and the matching compiled artifacts needed by Madeira:

- Madeira's FEX bridge and iOS/ARM64 JIT allocator.
- Wine's in-process process and wineserver bridges, plus the matching ARM64EC Windows DLL farm and Wine Unix libraries.
- DXMT's iOS Metal backend and its ARM64EC Windows-side DLLs.
- Madeira's Direct3D 12 implementation and the Apple Metal Shader Converter input it needs.
- The exact runtime/prefix packaging and launch sequence used by Madeira, including runtime setup, graphics and input integration.

The FEX, Wine, DXMT and D3D12 pieces are not interchangeable with upstream releases or a box64/wine64 pair. Madeira uses project-specific forks and builds them for a single-process iOS environment.

## Upstream build requirements

Start with the [Madeira build guide](https://github.com/willfaust/Madeira/blob/main/docs/BUILDING.md) and the upstream [README](https://github.com/willfaust/Madeira#building-from-source). The build guide documents required inputs that are not reproducibly available from a normal checkout, including LLVM toolchains, Apple's Metal Shader Converter package, generated native libraries and project-specific forks/submodules. Merely adding the Madeira repository as a submodule or copying Swift files would not link the runtime into iDeck.

The upstream app source and required licenses are available in [willfaust/Madeira](https://github.com/willfaust/Madeira). Review its current license and conversion exception before redistributing derived code or binaries.

## Runtime readiness contract in iDeck

WindowsEnvironment.hasRuntime(in:) now requires all of the following before allowing the legacy launch entry point to proceed:

- A bundled MadeiraRuntimeManifest.plist with ABI version 1 and flags for in-process FEX, Wine, DXMT and D3D12.
- Linked bridge symbols fex_initialize, wineserver_start, wine_process_start, madeira_dxmt_runtime_ready and madeira_d3d12_runtime_ready.

The manifest and the runtime-specific bridge symbols are deliberately not supplied as placeholders in this branch. The gate therefore reports the runtime as missing until the actual native components and bridges are built, linked, packaged and tested. Do not add a manifest claiming success before those checks are true.

## Remaining runtime work

1. Build the exact compatible native components with the upstream build scripts on a provisioned macOS/Xcode host.
2. Add the native bridge sources, headers and frameworks/static libraries to the iDeck Xcode project. The bridges must start Wine and FEX in-process; they must not relaunch a separate box64 executable as a substitute.
3. Integrate DXMT's Metal resources and the Direct3D 12 component into the app target and implement runtime-backed per-game graphics settings.
4. Replace the current legacy process launcher with the native bridge's launch/session/exit API.
5. Create and verify the runtime manifest as part of the successful build, not by hand.
6. Build the unsigned IPA in GitHub Actions, install it on the target iPad, and test startup, a plain Win32 application, Direct3D 9/11/12 games, Steam installation/launch, saves, input and clean session exit.

Until those steps pass, the UI and library work in this branch are groundwork, not a completed Windows runtime.
