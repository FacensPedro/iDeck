# iDeck

**iDeck is an experimental iOS and iPadOS app that combines a Steam game library, hosted iOS apps, and a Windows compatibility environment powered by [Madeira](https://github.com/willfaust/madeira).**

> **Project status:** An **interface-only IPA cannot run Windows games**. A **Madeira-native IPA** includes native FEX, Wine ARM64EC, DXMT, WineMetal, and D3D12 components, but successful compilation does **not** guarantee that a game starts, renders, or runs correctly on an iPad.

[Features](#features) · [Requirements](#requirements) · [Build an IPA](#build-an-ipa) · [Automatic Visual C++ setup](#automatic-microsoft-visual-c-setup) · [Troubleshooting](#troubleshooting) · [Documentation](#documentation)

## Features

| Component | What iDeck provides | Limitations |
| --- | --- | --- |
| Steam | Sign-in, owned-game library, metadata, and downloads | Some games require Steam's Windows client and DRM authentication |
| Windows | EXE import, Wine prefixes, game profiles, and the Madeira runtime | Requires an actual native IPA, FEX/JIT, and compatible Wine functionality |
| Graphics | Metal adapters, DXMT, WineMetal, D3D12, and MetalFX settings | Game rendering and performance require hardware testing |
| iOS app hosting | LiveContainer-inspired integration | Subject to iPadOS entitlements, signing, and sandbox restrictions |
| JIT | Integration with the external [StikDebug](https://github.com/StikDebug/StikDebug) workflow | iDeck cannot independently grant JIT permissions or bypass iOS security |
| Runtime caching | Precompiled Madeira kits through GitHub Actions cache or Git LFS | Requires a legitimate native build and permission to redistribute components |

iDeck combines SwiftUI, C/C++, Objective-C++, Wine, and native Metal interfaces. Its host adapters are not substitutes for a fully functional FEX or Wine runtime.

## Requirements

- **To build:** macOS, a compatible Xcode installation with the iOS/iPadOS 27 SDK, and the appropriate native toolchains.
- **To install:** An IPA properly signed and provisioned for your device.
- **To run Windows games:** A verified Madeira-native IPA, a functioning Wine prefix, appropriate graphics components, and JIT when required.
- **For some 32-bit Windows installers and games:** Optional WoW64 support must be present in the native build.

The Xcode project currently targets **iOS/iPadOS 27.0** as its minimum OS version.

## Build an IPA

### GitHub Actions

1. Open [Actions → iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml).
2. Choose the branch and select **Run workflow**.
3. For an interface-only build, disable **Require Madeira runtime**.
4. For an experimental Windows runtime, enable **Require Madeira runtime** and, when needed, **WoW64** or **Wine Mono**.
5. Review the Apple Metal Shader Converter license. Confirm the license option only if you have the necessary rights to use and distribute the component.
6. After the workflow finishes successfully, confirm which artifact it produced:
   - `iDeck-interface-only` — app interface only; **cannot execute Windows games**.
   - `iDeck-Madeira-native` — includes the native runtime, subject to device validation.

Automatic push and pull-request builds may produce only the interface-only IPA. Build success in Xcode does not necessarily mean final IPA packaging succeeded.

### Local builds on macOS

Interface-only:

```bash
bash scripts/build_ipa.sh
```

Native build (with the required toolchains and appropriate license rights):

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
bash scripts/build_native_runtime.sh
```

The output is `iDeck.ipa` when the required steps succeed. Set your own signing team, bundle identifiers, App Group, and provisioning configuration.

### Reuse precompiled FEX, Wine, and DXMT

iDeck can reuse compatible native kits stored in `runtime/prebuilt/ios-arm64/` (Git LFS) or `build/native-cache/` (Actions cache). To **require** an already-compiled runtime and prevent source compilation:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_PREBUILT_MODE=only \
bash scripts/build_ipa.sh
```

Without a matching kit, this mode fails rather than creating placeholder binaries. See [Precompiled Madeira runtime](docs/MADEIRA_PREBUILT_RUNTIME.md).

## Automatic Microsoft Visual C++ setup on the iPad

Some Windows games depend on Microsoft x64 C++ runtime DLLs such as `vcruntime140.dll`, `msvcp140.dll`, and optional MFC components.

**The first time you launch a Windows game or imported EXE, iDeck can prepare the Microsoft DLLs directly on the iPad:**

1. iDeck checks for a complete, previously verified set of 14 Microsoft x64 DLLs in `Documents/vcruntime` or the app bundle.
2. If missing, iDeck asks for permission to download and extract the [official Microsoft x64 Visual C++ Redistributable](https://aka.ms/vc14/vc_redist.x64.exe).
3. On approval, iDeck downloads the official Microsoft installer over HTTPS and **extracts its embedded CAB archives locally on the iPad** using a bundled open-source CAB decoder (`libmspack`). **The Windows installer is not executed.**
4. iDeck checks that all 14 required DLLs are present, Windows x64 PE files and contain an Authenticode certificate-table structure, then installs the files in `Documents/vcruntime`.
5. The Madeira Wine bridge makes the DLLs available to games through the prefix, preserving its native ARM64EC exemptions. Only when the files are successfully prepared does iDeck continue the game launch. Later launches reuse the files without downloading them again.

This is a **best-effort** compatibility feature. Cabinet contents can change between Microsoft versions; some release formats might not expose the CAB data in a way this decoder recognizes. Validating the presence of a PE certificate table is **not cryptographic verification of the Authenticode signature**. The app never claims successful installation if extraction fails. You may choose **Play without installing** to proceed without this prerequisite.

**Microsoft DLLs are not bundled into the GitHub repository or IPA.** The user downloads them directly from Microsoft upon approval. Review Microsoft's [license and redistribution conditions](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files). The bundled CAB decoder is **libmspack (LGPL-2.1)**; see [its license and source](iDeck/ThirdParty/libmspack/UPSTREAM.md).

### Manual fallback

If extraction fails or you already have compatible DLLs that you are authorized to use, place the necessary x64 DLLs under **Files → On My iPad → iDeck → vcruntime**. Use **Settings → Windows compatibility → Prepare Visual C++ folder** to create the folder.

See the [Microsoft Visual C++ DLL guide](docs/MICROSOFT_VISUAL_CPP_DLLS.md) and [official Microsoft downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).

## JIT and platform restrictions

StikDebug may provide the necessary JIT debugging workflow on supported devices. A JIT indicator does not prove FEX executable-memory allocation succeeded. Windows games, hosted apps, and native components remain subject to iOS/iPadOS signing, entitlements, and sandbox limitations.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| No Windows EXE starts | Confirm the IPA is `iDeck-Madeira-native`, the Wine prefix is prepared, and JIT/FEX is ready |
| Screen stays black | Check Wine initialization, DXMT/D3D12, Metal presentation, and game-specific requirements |
| Automatic Visual C++ setup fails | Check Internet access, download availability, WoW64 support, and whether Wine can run Microsoft's installer |
| Visual C++ download succeeds but DLL verification fails | The Windows installer may not have completed; review the Wine logs and use the manual fallback if appropriate |
| A 32-bit Windows app fails | Confirm that WoW64 is actually included and operational |
| GitHub Actions fails after `BUILD SUCCEEDED` | Inspect the **first real error** in packaging or native runtime validation |
| iDeck terminates after a few minutes | Inspect the full iPadOS `.ips` diagnostic; a blank screen alone does not establish that Metal caused the termination |

For more detail, read [Game startup and black-screen diagnostics](docs/IDECK_GAME_STARTUP_DIAGNOSTICS.md).

## Documentation

- [Microsoft Visual C++ DLL setup](docs/MICROSOFT_VISUAL_CPP_DLLS.md)
- [Precompiled Madeira runtime](docs/MADEIRA_PREBUILT_RUNTIME.md)
- [Game startup diagnostics](docs/IDECK_GAME_STARTUP_DIAGNOSTICS.md)
- [Madeira integration status](docs/MADEIRA_RUNTIME_INTEGRATION.md)
- [Native Madeira build](docs/IDECK_MADEIRA_NATIVE_BUILD.md)
- [Native linking and verification](docs/MADEIRA_NATIVE_LINKING.md)
- [Native runtime modules](docs/NATIVE_RUNTIME_MODULES.md)
- [iPadOS memory management](docs/IOS_MEMORY_MANAGEMENT.md)
- [Native performance](docs/NATIVE_PERFORMANCE.md)
- [Steam download performance](docs/STEAM_DOWNLOAD_PERFORMANCE.md)

## Licenses, security, and attribution

iDeck integrates or adapts code and techniques from [Madeira](https://github.com/willfaust/madeira), [FEX](https://github.com/FEX-Emu/FEX), [Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt), [StikDebug](https://github.com/StikDebug/StikDebug), and [LiveContainer](https://github.com/LiveContainer/LiveContainer).

Review the repository's [license notices](LICENSES) and the applicable upstream terms. Do not upload proprietary Microsoft DLLs, the Apple Metal Shader Converter, or distributing artifacts that contain them without the appropriate redistribution rights. Remove credentials, account tokens, and personal data from diagnostics.

## Contributing

When reporting an issue, include the iPad/iPhone model, iOS/iPadOS version, game, IPA type (interface-only or Madeira-native), and relevant build or device logs. Reproducible test cases and focused pull requests are welcome.

---

**iDeck is an experimental project, not a verified Windows compatibility product for iOS/iPadOS.**
