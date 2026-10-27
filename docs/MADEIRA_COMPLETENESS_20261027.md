# Madeira runtime integration: operational readiness

This document describes the native integration checks applied to the iDeck app.
The source tree does not include precompiled FEX/Wine/DXMT archives; build on
macOS with Xcode and the pinned Madeira forks. Do not confuse source checkout,
static-link symbol presence or an IPA file with a device-tested Windows runtime.

## Display and session startup

Both imported EXE files and Steam games display a Metal-backed session before
launching Wine. The coordinator waits until the MTKView is attached to a
window, has a valid drawable size, and exports the Madeira display shim. A
missing surface ends the attempt with an actionable error instead of launching
the guest invisibly. The native symbols `macdrv_functions`,
`madeira_display_set_layer`, `winios_screen_size` and
`winios_display_mode_changed` are required by the bundle verifier.

## Resource layout

The upstream Wine bridge resolves resources at the TOP LEVEL of iDeck.app,
including `arm64ec-windows/`, `aarch64-windows/`, `nls/`, `cacert.pem`,
and `d3d12/`. The packaging verifier checks both those live locations and the
`MadeiraRuntime/` mirror used for compatibility with Windows signers. The
required minimum set of native/guest symbols and critical DLLs is audited;
this is not proof that all installed games' dependency imports resolve.

## Microsoft VC++ and .NET

The official Microsoft VC++ runtime is not stored in the Madeira repository.
If the owner has the required redistribution rights, stage all 14 authentic
x64 runtime DLLs using `IDECK_VCRUNTIME_DIR` during build. With
`IDECK_REQUIRE_VCRUNTIME=1`, the build fails when they are absent. When not
supplied, the build warns and games requiring these Microsoft DLLs may fail.
The Wine bridge reads `x86_64-vcruntime/` from the app bundle; do not
rename x64 DLLs to ARM64EC or replace them with placeholders.

Wine Mono is optional: `IDECK_BUNDLE_WINE_MONO=1` fetches the upstream
pinned WineHQ distribution with its SHA-256 verification and calls Madeira's
bundle script. The upstream script patches one version-pinned mscorlib
method; consult its licence and source comments before redistributing.

Set `IDECK_BUILD_WOW64=1` to compile Madeira's FEX WoW64 DLL and full
i386 Wine/DXMT farm. The build and verifier will reject partial results.
The iDeck launcher now identifies PE32 i386 headers and routes those
executables to the native Madeira WoW64 loader only if the required
i386 and aarch64 files were packaged. These build paths have not been
validated on macOS or hardware in this change; do not claim working
32-bit games until those tests succeed.

## Revisions and validation

`scripts/fetch_madeira_sources.sh` pins a tested source revision. Do not
silently update to upstream main because Wine/DXMT/FEX ABI and build scripts
may change together. Rebase selectively with source, host tests and a
real-device test plan.

Run the host tests for staging, bundle verification and startup diagnostics.
Then build with `IDECK_REQUIRE_MADEIRA=1` and review the license for the
Apple Metal Shader Converter before setting the acceptance flag. A successful
build must be tested on a signed iPadOS installation with a live JIT
debugger. Verify actual rendered frames and clean shutdown.
