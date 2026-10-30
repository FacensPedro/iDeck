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
  --acknowledge-license
```

The helper extracts only the iOS library, original embedded license
and a JSON provenance record, verifies the exact package SHA-256,
confirms Mach-O ARM64/iOS, and never installs or executes the macOS
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

### Public-source D3D12 guest validation

The manual GitHub workflow
`.github/workflows/madeira-expanded-profiles.yml`, option
`d3d12-guest-pe`, compiles the upstream ARM64EC
`madeira_d3d12.dll`, `d3d12.dll` and `d3d12core.dll` without
a proprietary Apple runtime, then rejects any incorrect PE architecture.
It deliberately **does not output a D3D12 IPA**. The in-app D3D12
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
