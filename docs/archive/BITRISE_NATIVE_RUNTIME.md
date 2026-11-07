# Native Madeira runtime on Bitrise

This pipeline builds FEXCore, the ARM64EC FEX guest DLL, Wine's iOS libraries and wineserver, DXMT, D3D12 and the iDeck app. It does not retrofit an already-compiled IPA.

## Bitrise setup

1. Choose a macOS Apple Silicon stack with a full Xcode installation and the iPhoneOS SDK.
2. Use a Git Clone step configured to check out the branch containing the native-build scripts.
3. Add one Script step with:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   cd "${BITRISE_SOURCE_DIR:?}"
   bash scripts/bitrise_native_runtime.sh
   ```

4. Add Deploy to Bitrise.io after the script. The artifact will be named `iDeck.ipa`.
5. Review Apple's Metal Shader Converter license and the project's redistribution terms. Only when authorized, set `IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1` in the Bitrise workflow environment.

## Build details

- The toolchain bootstrap downloads LLVM-MinGW 20260421 for macOS, verifies its pinned SHA-256, then compiles LLVM 15.0.7 for iOS when missing.
- Building LLVM from source can take hours and consume significant disk/RAM. For repeat builds, provision a cached `vendor/Madeira/toolchains` directory with the exact LLVM-MinGW and LLVM iOS toolchains before running the script.
- `IDECK_LLVM_JOBS` defaults to `4` to limit memory use. Tune it for the Bitrise machine size.
- `IDECK_MADEIRA_ROOT` can point to an already-prepared Madeira checkout. The source fetch script pins a Madeira commit and recursively initializes its forks.
- The native iDeck app is compiled in Debug configuration, because upstream Madeira documents crashes with Release for guest execution.
- The build fails if required native libraries, exported symbols, Windows PE modules, shader converter or manifest are missing. It does not silently fall back to an interface-only IPA.
- The output is an unsigned IPA. Installers such as AltStore or SideStore must sign it for the destination device, including any bundled dynamic libraries. A successful build does not prove device runtime functionality or JIT availability.
- Madeira's licensing and the Metal Shader Converter terms must be checked before redistribution. Do not set the converter-acceptance flag automatically without authorization.

The LLVM iOS rebuild steps are based on upstream Madeira's documented but not fully clean-room-verified toolchain recipe. Actual Bitrise compilation and device testing are still required.
