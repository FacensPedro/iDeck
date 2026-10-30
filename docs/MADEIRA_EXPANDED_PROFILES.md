# iDeck: Metal Shader Converter 4.0 beta 3, WoW64 and phases 8–11

## What is implemented, and what is not

- Stage 6: a genuine unsigned D3D11 IPA has been compiled in GitHub Actions.
- Stage 7: native FEX/Wine JIT W^X checks and a read-only on-device snapshot are in the app; live StikDebug/BRK execution remains an iPad test.
- Stages 8–11: this change supplies a fail-closed evidence checklist, signed-IPA/proof hashes and offline compatibility preflight. They are NOT complete until an actual iPad is used and the observations are reviewed.
- Optional WoW64 now has a separate D3D11 build profile. Compiling PE32 modules or inspecting an EXE is not proof that a 32-bit guest launches.
- Optional D3D12 accepts an owner-supplied Apple 4.0 beta 3 installer, validates the exact archive hash, iPhoneOS ARM64 Mach-O and embedded license, and stages only the iOS dylib with its provenance. The package itself must not be checked into GitHub or public build artifacts.

## Apple Metal Shader Converter 4.0 beta 3

The exact user-provided `.pkg` has SHA-256:

`449833211e4ef0d46bfaa94848e801acff49e226d3c348bba0673f13716be622`

The archive is an XAR installer with a gzip old-ASCII CPIO payload. It includes
`usr/local/lib_iOS/libmetalirconverter.dylib` (30,189,152 bytes,
Mach-O ARM64, `LC_BUILD_VERSION` iOS, minimum 13.0, SDK 26.4),
the separate macOS library, headers and a macOS command-line tool.
Do not substitute the macOS dylib for the iOS runtime.

The package's embedded **License.rtf**, section 2.B, gives a limited
license to distribute the Dynamic Libraries for the sole purpose of
shader conversion. Other restrictions apply, including use on
Apple-branded devices, and open-source compliance for Wine/FEX/DXMT
must also be considered. This is a technical source review, not a legal
opinion or a blanket license to redistribute the installer.

The default D3D11 profile remains converter-free. **Do not upload a
proprietary Apple package or extracted Apple binaries as source,
PR attachments or test fixtures.**

On a macOS machine with Xcode and legally obtained package:

```bash
python3 scripts/prepare_apple_msc_beta3.py \
  --pkg "/private/path/Metal_Shader_Converter_4.0_beta_3.pkg" \
  --destination vendor/Madeira/app/Madeira/d3d12 \
  --headers-destination vendor/Madeira/madeira-d3d12/third_party/metal-shader-converter/include \
  --acknowledge-license
```

The helper extracts only the iOS library, original embedded license
and a JSON provenance record, verifies the exact package SHA-256,
confirms Mach-O ARM64/iOS, installs matching headers into the local Madeira include tree, and never installs or executes the macOS
installer. It does not rewrite or redistribute Apple's files via GitHub.

For an owner-authorized local D3D12 IPA build:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_MADEIRA_GRAPHICS=d3d12 \
IDECK_BUILD_WOW64=0 \
IDECK_PREBUILT_MODE=off \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_MSC_PKG="/private/path/Metal_Shader_Converter_4.0_beta_3.pkg" \
bash scripts/build_ipa.sh
```

Setting the license variable records the build owner's decision and
does not grant rights they do not already have. The iOS library must
be signed in the final signed app as required by Apple; unsigned CI
artifacts do not prove runtime `dlopen` works. Use
`scripts/verify_signed_madeira_app.py` after signing.

The strict bundle audit now checks the actual iPhoneOS ARM64 Mach-O header and
`LC_BUILD_VERSION` in **both** staged copies and the owner-provided source,
requires the exact audited 30,189,152-byte beta-3 library, and cross-checks
the embedded RTF license and SDK/minimum-iOS provenance. A self-consistent JSON
hash for a non-Mach-O file is never sufficient. These checks verify package
integrity, not legal permission or runtime Metal behavior.

#### Combined D3D12 + WoW64 profile

On the owner's Mac, with the exact legal Apple 4.0 beta 3 installer and Xcode:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_MADEIRA_GRAPHICS=d3d12 \
IDECK_BUILD_WOW64=1 \
IDECK_PREBUILT_MODE=off \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_MSC_PKG="/private/path/Metal_Shader_Converter_4.0_beta_3.pkg" \
bash scripts/build_ipa.sh
```

This requests real FEX/Wine PE32 host modules, native ARM64EC D3D12 frontends
and an unsigned converter-bearing iOS IPA. On a signed extracted app, run
`python3 scripts/verify_signed_madeira_app.py --app PATH_TO_SIGNED_iDeck.app`
on macOS. A build or valid signature does **not** prove 32-bit execution on the
iPad or a D3D12 first frame.

### Public-source D3D12 guest validation

The manual GitHub workflow
`.github/workflows/madeira-expanded-profiles.yml`, option
`d3d12-guest-pe`, compiles the upstream ARM64EC
`madeira_d3d12.dll`, `d3d12.dll` and `d3d12core.dll` without
a proprietary Apple runtime, then rejects any incorrect PE architecture.
It deliberately **does not output a D3D12 IPA**.
The additional `d3d12-wow64-guest-pe` manual workflow compiles public D3D12
frontends together with the complete Wine/FEX i386/ARM64 WoW64 host farm,
and audits PE32 and ARM64 host machines. It does not use or publish Apple's
converter and never produces a D3D12 IPA. The in-app D3D12
shader converter and visible cube require a separate signed-device run
with an authorized iOS converter.

## D3D11 + WoW64 (experimental)

For a local unsigned D3D11 build with the additional PE32 host/Wine
farm, use:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_MADEIRA_GRAPHICS=d3d11 \
IDECK_BUILD_WOW64=1 \
IDECK_PREBUILT_MODE=off \
bash scripts/build_ipa.sh
```

The build now calls the existing published
`build/fex-wow64/build.sh` and `build/wine-i386/build.sh` from
the actual Madeira checkout, and the stager preserves the verified
`i386-windows` farm, `xtajit.dll`, `wow64.dll` and
`wow64win.dll`, without including D3D12. It checks required PE32
and ARM64 host modules and aborts when they are missing.
No fake WoW64 binaries or instruction interpreter is introduced.

The GitHub workflow option `d3d11-wow64` performs an expensive
source build on macOS by explicit manual dispatch and, if successful,
publishes a direct **unsigned** IPA. The host tests run on PRs without
spending several hours compiling the whole Wine i386 farm.

## Additional compatibility triage

Inspect a legally obtained Windows executable without executing it:

```bash
python3 scripts/inspect_windows_game_pe.py "/path/to/Game.exe" \
  --output game-preflight.json
```

This checks PE headers, x86/x64 machine type, imports for D3D11,
D3D12, Vulkan, VC++ runtime, .NET, XInput, DirectInput and XAudio.
It marks whether a PE32 game **needs WoW64**, but its hints cannot
detect delay-loaded libraries, anti-cheat, OS calls, actual performance
or runtime compatibility. It never installs or runs the EXE.

## Original Windows guest probes for phases 8–9

The repository includes source code for two deterministic, noncommercial
Win32 startup probes and one D3D11 graphics probe:

- `tests/device/ideck_guest_smoke.c`: builds x86/PE32 and x64/PE32+.
  A real Windows guest process records its bitness and PID into
  `%TEMP%\\ideck-guest-smoke-32.log` or `...64.log`, then exits zero.
  The app must actually run the EXE under Wine; the presence of the
  compiled EXE proves nothing about guest startup.
- `tests/device/ideck_d3d11_frame_probe.cpp`: a real
  `D3D11CreateDeviceAndSwapChain` + `ClearRenderTargetView` +
  `Present` path in **both x64 and i386** with alternating red/blue frames. A screen capture
  from the physical iPad should show both colors **from the guest**,
  not the Wine splash screen or an iDeck placeholder.
- `scripts/build_madeira_device_probes.sh` builds these via
  the exact llvm-mingw x86-64 and i686 compilers installed by the
  Madeira toolchain scripts and inspects their actual PE machines/imports.

```bash
bash scripts/build_madeira_device_probes.sh
```

For the WoW64 profile, the acceptance auditor additionally requires a real
PNG/JPEG/MP4 capture of `ideck-d3d11-frame-probe-x86.exe` rendering on an
iPad. A PE32 process-start log alone does not prove that 32-bit D3D11 works.

The manual GitHub optional-profile build publishes the executables as
an artifact for local transfer onto the iPad (no proprietary game files).
For D3D12, the upstream Madeira test farm also includes
`d3d12-cube-x64.exe` and related public-source shader tests, which
still need to be compiled and launched in the signed D3D12 IPA.

## Native executable dispatch and session lifecycle hardening

The iDeck host now inspects the **actual** PE32/PE32+ COFF machine,
optional-header magic, file bounds and DOS/NT signatures in a shared native
validator before launching a Windows guest. The JSON `is32Bit` hint is not
trusted to select a backend; x86 executables always require a complete i386
Wine farm and FEX WoW64 DLLs, even if the caller supplied an incorrect hint.
This prevents a PE32 installer being handed to the x64 path. On iOS, the
Swift launcher and the native Madeira entry point use the same validator.

Native D3D11 and D3D12 builds default to `IDECK_BUILD_WOW64=1`. For the
lighter intentionally x64-only runtime, explicitly set
`IDECK_BUILD_WOW64=0`; the D3D11 strict bundle verifier continues to
reject accidental WoW64 assets in that case. Building full WoW64 is more
expensive than a no-WoW64 source build.

Wine guest startup checks for the asynchronously running guest thread for up
to 500 ms instead of declaring failure from a single immediate poll.
After **both** Wine and wineserver threads have actually stopped, iDeck
releases the gamepad session and clears the inherited Steam dock state.

CI checks the native PE inspector as C and C++, and exercises valid x86/x64
headers and malformed/unsupported machines. These are host-level tests,
not evidence of a launched Windows guest or on-device rendering. Signed
IPA installation, two successful guest sessions, first frames, audio,
input, legal attribution and reboot-cycle stability remain subject to the
physical-device evidence gate described below.

## Stages 8–11: real iPad evidence, not simulated PASS

Create a local evidence checklist (all fields are initially NOT RUN):

```bash
python3 scripts/verify_madeira_device_acceptance.py \
  --write-template device-evidence.json --graphics d3d11
```

For D3D12 and 32-bit apps, add `--graphics d3d12 --wow64`;
for VC++/.NET/HID tests add `--compatibility`.

Record the exact GitHub Actions commit/run, unsigned and signed IPA
SHA-256, actual iPad/iPadOS build, real signing team and corresponding
source URL. For each observation, set `status: PASS` only after
actually performing it, and supply a local relative
`evidence_file` and its real SHA-256. The auditor rejects
`FAIL`, `NOT RUN`, mismatched evidence hashes, missing signed IPA
and non-image/video first-frame material.

Test on the physical iPad:

- **Phase 8:** start a minimal legal x86-64 Windows EXE, inspect real
  FEX + Wine process/wineserver logs, shut it down normally, and
  launch a second EXE in the same app session.
- **Phase 9:** record a first **guest-generated** D3D11/D3D12 frame
  and subsequent changing frames, audible guest audio, touch,
  gamepad input and orientation handling.
- **Phase 10:** re-sign the unsigned IPA with authorized entitlements,
  independently verify the signed IPA, include the correct GPL/LGPL/MIT
  notices, corresponding sources and Apple's applicable converter
  license for D3D12.
- **Phase 11:** repeat cold-start, restart, JIT attached/detached,
  guest and wineserver close, and multi-session regression cases,
  retaining a redacted test report.

Once the signed IPA and local recordings/logs exist:

```bash
python3 scripts/verify_madeira_device_acceptance.py \
  --evidence device-evidence.json \
  --root "/private/path/real-device-artifacts" \
  --receipt acceptance-integrity-receipt.json
```

The output is **READY FOR HUMAN REVIEW**, not automatic proof that
games work. A reviewer must inspect the evidence and confirm actual
guest pixels and audio. Do not put Apple signing private keys, pairing
files, Steam tokens, game binaries or the private device evidence in a
public PR.

See `docs/MADEIRA_DEVICE_ACCEPTANCE.md` for the existing full
physical-device protocol.
