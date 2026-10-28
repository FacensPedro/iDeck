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

## Automatic Microsoft Visual C++ setup

Some Windows games require Microsoft Visual C++ runtime DLLs, including `vcruntime140.dll`, `msvcp140.dll`, and `msvcp140_1.dll`.

**On the first Windows game or EXE launch for a Wine prefix:**

1. If compatible user-provided DLLs or a previously verified installation are available, iDeck skips setup.
2. Otherwise, iDeck offers a **one-time installation confirmation** before launching the game.
3. After you choose **Install and play**, iDeck downloads the official [Microsoft x64 Visual C++ Redistributable](https://aka.ms/vc14/vc_redist.x64.exe) **directly from Microsoft**, not from a DLL mirror or this GitHub repository.
4. iDeck attempts to run the Microsoft installer inside the Wine prefix with `/install /quiet /norestart`, waits for the Wine installation session to end, and checks for actual x64 runtime DLLs.
5. **Only when the installation is verified** does iDeck continue to launch the game. On future launches in that prefix, setup is skipped.

**Important limitations:** The Microsoft installer may require **WoW64**, Windows services, or other features not yet supported by this Wine build. If it fails, iDeck reports the failure rather than pretending DLLs were installed. Choose **Play without installing** to skip the setup for that launch. Downloading the installer is not the same as guaranteeing it can run on iPadOS. You must review and agree to any applicable Microsoft licensing terms before installing.

**No Microsoft DLLs or installers are committed to the iDeck repository or automatically bundled into the IPA.** On-device downloads are made from Microsoft at your request. Microsoft's Visual C++ licensing still governs their use and redistribution.

### Manual fallback

If the automatic installer cannot run in your Wine environment, compatible DLLs you are authorized to use can be placed at:

```text
Files/
└── On My iPad/
    └── iDeck/
        └── vcruntime/
            ├── vcruntime140.dll
            ├── msvcp140.dll
            └── msvcp140_1.dll
```

Use **Settings → Windows compatibility → Prepare Visual C++ folder** to create the directory, then transfer the necessary DLLs using Files or Apple Devices. These are **examples**, not a guaranteed complete set. The installer `vc_redist.x64.exe` itself is not a DLL.

See the [Microsoft Visual C++ DLL guide](docs/MICROSOFT_VISUAL_CPP_DLLS.md), [official Microsoft downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist), and [Microsoft redistribution terms](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files).

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
