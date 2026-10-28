# iDeck

**iDeck is an experimental iOS and iPadOS app that combines a Steam game library, hosted iOS apps, and a Windows compatibility environment powered by [Madeira](https://github.com/willfaust/madeira).**

> **Project status:** An **interface-only IPA cannot run Windows games**. A **Madeira-native IPA** includes native FEX, Wine ARM64EC, DXMT, WineMetal, and D3D12 components, but successful compilation does **not** guarantee that a game starts, renders, or runs correctly on an iPad.

[Features](#features) · [Requirements](#requirements) · [Build an IPA](#build-an-ipa) · [Automatic Visual C++ setup](#automatic-microsoft-visual-c-setup) · [Troubleshooting](#troubleshooting) · [Documentation](#documentation)

## Features

| Component | What iDeck provides | Limitations |
| --- | --- | --- |
| Steam | Sign-in, owned-game library, metadata, and downloads | Some games require Steam's Windows client and DRM authentication |
| Windows | EXE import, Wine prefixes, game profiles, and the Madeira runtime | Requires an actual native IPA, FEX/JIT, and compatible Wine functionality |
| WoW64 (32-bit x86) | Native Madeira builds include the i386 FEX translator, 32-bit Wine DLL farm and WoW64 host DLLs by default | Real device compatibility depends on the JIT pool, Wine prefix and individual game requirements |
| Graphics | Metal adapters, DXMT, WineMetal, D3D12, and MetalFX settings | Game rendering and performance require hardware testing |
| iOS app hosting | LiveContainer-inspired integration | Subject to iPadOS entitlements, signing, and sandbox restrictions |
| JIT | Integration with the external [StikDebug](https://github.com/StikDebug/StikDebug) workflow | iDeck cannot independently grant JIT permissions or bypass iOS security |
| Runtime caching | Precompiled Madeira kits through GitHub Actions cache or Git LFS | Requires a legitimate native build and permission to redistribute components |

iDeck combines SwiftUI, C/C++, Objective-C++, Wine, and native Metal interfaces. Its host adapters are not substitutes for a fully functional FEX or Wine runtime.

## Requirements

- **To build:** macOS, a compatible Xcode installation with the iOS/iPadOS 27 SDK, and the appropriate native toolchains.
- **To install:** An IPA properly signed and provisioned for your device.
- **To run Windows games:** A verified Madeira-native IPA, a functioning Wine prefix, appropriate graphics components, and JIT when required.
- **For 32-bit Windows installers and games (PE32/i386):** WoW64 is enabled by default in Madeira-native builds. The IPA must contain a complete, validated i386 Wine DLL farm and FEX/WoW64 components; interface-only IPAs cannot execute Windows programs.

The Xcode project currently targets **iOS/iPadOS 26.0** as its minimum OS version. Compilation still requires the **iOS 27 SDK**. Signed IPA launch compatibility and native JIT functionality must be checked on a real device; lowering the deployment target does not grant executable-memory permissions.

## Build an IPA

### GitHub Actions

1. Open [Actions → iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml).
2. Choose the branch and select **Run workflow**.
3. For an interface-only build, disable **Require Madeira runtime**.
4. For an experimental Windows runtime, enable **Require Madeira runtime**. **WoW64 is selected by default** for 32-bit Windows programs; leave it enabled. Select **Wine Mono** if needed for compatible .NET apps.
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

Native build (WoW64 for i386 Windows apps is included by default, with the required toolchains and appropriate license rights):

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
bash scripts/build_native_runtime.sh
```

The output is `iDeck.ipa` when the required steps succeed. The default unsigned
bundle identifier is **`com.ideck.ideck`**; its VPN extension uses
`com.ideck.ideck.VPNExtension` and the extension's App Group entitlement
is `group.com.ideck.ideck`. Configure compatible signing identities,
provisioning profiles and App Group capabilities when signing. Third-party
sideloaders such as AltStore may append a team-specific suffix (for example,
`com.ideck.ideck.<suffix>`) or rewrite identifiers while resigning: that
suffix cannot be controlled by changing the Xcode project's default ID.
Make sure any extension remains signed and its bundle ID matches the main
app's VPN provider reference. **Changing the app identifier is treated as
a separate app by iPadOS** and may prevent access to data stored under the
old identifier; back up the existing iDeck data before replacing the app.

### WoW64: 32-bit Windows applications

**WoW64 is included by default in Madeira-native builds.** It combines the
32-bit x86 guest translator (`aarch64-windows/xtajit.dll`), Madeira's
`wow64.dll` and `wow64win.dll` host modules, and the i386 Wine/DXMT
DLLs under `i386-windows/`. The native launcher detects PE32/i386
executables and routes them through Wine's WoW64 path, including the
`C:\\windows\\syswow64` prefix farm. A 64-bit Wine prefix (`WINEARCH=win64`)
is intentional: WoW64 runs 32-bit apps inside that environment.

To build from source with both 64-bit and 32-bit support:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_BUILD_WOW64=1 \
bash scripts/build_ipa.sh
```

GitHub Actions → **iOS Build** → **Build WoW64** is enabled by default.
For an intentionally 64-bit-only IPA, set `IDECK_BUILD_WOW64=0` or
disable that checkbox. WoW64 is not provided by an interface-only IPA.

The build rejects missing WoW64 components when enabled; runtime checks
also verify the bundle manifest and required DLLs before attempting a
32-bit launch. This is **experimental compatibility**, not proof that
a particular 32-bit game, installer, DRM component or Steam client will
run on an iPad. A compatible native IPA, JIT/debugger preparation and
on-device testing are still necessary.

### Reuse precompiled FEX, Wine, and DXMT

iDeck can reuse compatible native kits stored in `runtime/prebuilt/ios-arm64/` (Git LFS) or `build/native-cache/` (Actions cache). To **require** an already-compiled runtime and prevent source compilation:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_PREBUILT_MODE=only \
bash scripts/build_ipa.sh
```

Without a matching kit, this mode fails rather than creating placeholder binaries. See [Precompiled Madeira runtime](docs/MADEIRA_PREBUILT_RUNTIME.md).

## Faster Steam game installations

iDeck fetches authorized Steam depot chunks concurrently from geographically selected CDN hosts. For game updates, interrupted downloads and repairs, the installer verifies existing file chunks in bounded, sequential read blocks before downloading. Every reusable chunk must match the manifest's SHA-1; only changed or missing chunks are fetched. This reduces redundant network traffic, especially when files are already on the device.

Concurrent downloads automatically respect device thermal conditions and Low Power Mode. Existing download journals are preserved on cancellation; progress distinguishes **Checking existing files** from **Downloading** and reports the amount of verified content reused. Actual transfer speed depends on network, CDN and device conditions; no fixed 2× performance guarantee is made.

## Automatic Microsoft Visual C++ setup on the iPad

Some Windows games depend on Microsoft x64 C++ runtime DLLs such as `vcruntime140.dll`, `msvcp140.dll`, and optional MFC components.

**The first time you launch a Windows game or imported EXE, iDeck can prepare the Microsoft DLLs directly on the iPad:**

1. iDeck checks for a complete, previously verified set of 14 Microsoft x64 DLLs in `Documents/vcruntime` or the app bundle.
2. If missing, iDeck asks for permission to download and extract the [official Microsoft x64 Visual C++ Redistributable](https://aka.ms/vc14/vc_redist.x64.exe).
3. On approval, iDeck downloads the official Microsoft installer over HTTPS and **extracts its embedded CAB archives locally on the iPad**, including nested Microsoft CAB payloads such as `a10` and `a11`, using a bundled open-source CAB decoder (`libmspack`). **The Windows installer is not executed.**
4. iDeck checks that all 14 required DLLs are present, Windows x64 PE files and contain an Authenticode certificate-table structure, then installs the files in `Documents/vcruntime`.
5. The Madeira Wine bridge makes the DLLs available to games through the prefix, preserving its native ARM64EC exemptions. Only when the files are successfully prepared does iDeck continue the game launch. Later launches reuse the files without downloading them again.

This is a **best-effort** compatibility feature. Cabinet contents can change between Microsoft versions; some release formats might not expose the CAB data in a way this decoder recognizes. Validating the presence of a PE certificate table is **not cryptographic verification of the Authenticode signature**. The app never claims successful installation if extraction fails. You may choose **Play without installing** to proceed without this prerequisite.

**Microsoft DLLs are not bundled into the GitHub repository or IPA.** The user downloads them directly from Microsoft upon approval. Review Microsoft's [license and redistribution conditions](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files). The bundled CAB decoder is **libmspack (LGPL-2.1)**; see [its license and source](iDeck/ThirdParty/libmspack/UPSTREAM.md).

### Manual fallback

If extraction fails or you already have compatible DLLs that you are authorized to use, place the necessary x64 DLLs under **Files → On My iPad → iDeck → vcruntime**. Create the folder manually with the Files app if automatic installation has not already created it.

See the [Microsoft Visual C++ DLL guide](docs/MICROSOFT_VISUAL_CPP_DLLS.md) and [official Microsoft downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).

## JIT and platform restrictions

StikDebug may provide the necessary JIT debugging workflow on supported devices. Request it from **inside iDeck**, which passes the bundled `universal.js` BRK handler to StikDebug; enabling JIT in the StikDebug app list alone may detach the debugger before Wine can map its RX/RW pool. A JIT indicator does not prove FEX executable-memory allocation succeeded. Windows games, hosted apps, and native components remain subject to iOS/iPadOS signing, entitlements, and sandbox limitations.

## Wine session progress and close button

The emulated-game screen shows a **startup milestone percentage** for environment preparation, Wine/FEX startup and the first rendered Metal frame. This number is not the game's own loading progress: reaching 90% only means Wine started and the app is waiting for the first frame. 100% is shown only after the presentation counter advances.

The **X** button requests a graceful Windows close using the same Alt+F4 keyboard event queue as Madeira. If the game remains active, the Metal surface is **not** detached. If the keyboard bridge is unavailable or the game is frozen, use the game's own menu or close iDeck using the iPadOS app switcher. As with Madeira, the current in-process Wine server can run only one session in each iDeck process.

For launchers that create a child game process and exit, each game's settings offer **Keep child game processes running (experimental)**. It enables Madeira's opt-in `MADEIRA_WAIT_CHILDREN=1` for that game only. Leave it off for ordinary programs: it can extend or hang the Wine session after gameplay.

The IPA requests **increased-memory-limit** when its signing profile permits it. The entitlement is never guaranteed by declaring it in the project file; check the signed application's granted entitlements.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| App closes immediately when opened | The iDeck home screen no longer probes Wine/FEX JIT, Steam Keychain or native memory pools. Check the signed IPA, iPadOS 26.0+ requirement and the iPadOS `.ips` crash report. If the console never shows `[iDeck startup] SwiftUI App initialized`, investigate dyld/loading, code signing or OS compatibility; a passing GitHub build cannot verify device launch. |
| No Windows EXE starts | Confirm the IPA is `iDeck-Madeira-native`, the Wine prefix is prepared, and JIT/FEX is ready |
| Wine ARM64EC JIT pool allocation fails | Request JIT from iDeck so StikDebug loads its bundled `universal.js`, leave the debugger connected until the RX/RW pools are mapped, and look for `[iDeck Wine JIT]` logs showing the first failed allocation, remap or protection step. The native runtime retries 384/256/192/128/96/64 MiB; insufficient virtual address space or a debugger without the BRK handler can still prevent startup. |
| Screen stays black | Check Wine initialization, DXMT/D3D12, Metal presentation, and game-specific requirements |
| Wine stops or exits instantly | Read the exact Wine exit code or NTSTATUS (e.g. `0xC0000135`: missing DLL); inspect Wine/FEX logs. Some games also require the real Steam client or hand off to another process. |
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
- [Madeira vs. iDeck Windows runtime differences](docs/WINE_RUNTIME_GAP_ANALYSIS.md)
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
