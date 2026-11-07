# iDeck

**iDeck** is an experimental Windows game compatibility app for iPhone and iPad, built around the [Madeira](https://github.com/willfaust/madeira) runtime. It brings game libraries, downloads, and Windows game launching together in a native iOS/iPadOS interface.

> **Status:** Under active development. A successful build does not guarantee that a Windows game will launch or run correctly. Windows execution requires a Madeira-native build; interface-only builds cannot run Windows applications.

## Features

- **Game libraries:** Steam, GOG, Epic Games and EA integration, with game management and downloads.
- **Windows compatibility:** Madeira Core with FEX, Wine ARM64EC, WineServer and optional WoW64 support for 32-bit applications.
- **Graphics:** DXMT, WineMetal and Direct3D 12 integration, with graphics options including MetalFX and experimental alternative renderers.
- **Game controls:** Game controller and touch-input support.
- **Runtime setup:** Wine prefixes, Madeira Dock, Wine Mono, Wine Gecko and Visual C++ dependency preparation.
- **JIT:** Integration with StikDebug for devices and configurations that support it.
- **iRelay:** Companion-device transfer integration, including local game installation workflows.
- **Diagnostics:** Wine logs, runtime status and troubleshooting information.

Feature availability depends on the build configuration, installed runtime components and device compatibility.

## Requirements

- An iPhone or iPad running **iOS/iPadOS 26.0 or later**.
- A correctly signed iDeck IPA.
- A complete **Madeira-native** build to run Windows software.
- Working JIT permissions and a compatible Wine environment when required.

Building from source requires macOS, Xcode with the iOS 27 SDK and the appropriate native toolchains. Some optional graphics components have separate licensing requirements.

## Installation

Download a build from [Releases](https://github.com/FacensPedro/iDeck/releases) and install the IPA using a compatible signing method. Complete the initial runtime setup in iDeck before launching Windows games.

**Important:** Not every release or CI artifact contains the native Madeira runtime. An interface-only IPA provides the interface but cannot execute Windows games.

## Building

Use [GitHub Actions — iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml) for automated builds. Select a Madeira-native build when Windows game execution is required, and enable WoW64 if you need 32-bit Windows compatibility.

For a local interface-only build on macOS:

```bash
bash scripts/build_ipa.sh
```

Native builds require the Madeira dependencies and supported build configuration. See [Native build documentation](docs/IDECK_MADEIRA_NATIVE_BUILD.md) and [Precompiled runtime](docs/MADEIRA_PREBUILT_RUNTIME.md).

## Compatibility and limitations

iDeck uses Madeira's FEX and Wine components to provide Windows compatibility on Apple hardware. DXMT and the Direct3D 12 integration translate supported graphics workloads for Metal. WoW64 supports 32-bit Windows applications when its required components are included in the IPA.

Game compatibility varies. JIT availability, Wine dependencies, DRM, launchers, graphics features, memory limits and iOS restrictions can prevent a game from starting or rendering correctly. iDeck does not bypass iOS security restrictions or guarantee compatibility with individual games.

## Troubleshooting

If a game does not start, verify that the installed IPA includes the native runtime, that the Wine environment is prepared and that JIT is active when needed. Review the Wine and iDeck diagnostic logs for the actual error rather than relying on the loading screen alone.

See [Game startup diagnostics](docs/IDECK_GAME_STARTUP_DIAGNOSTICS.md) and [Architecture](docs/ARCHITECTURE.md).

## Credits and licenses

iDeck integrates and adapts work from [Madeira](https://github.com/willfaust/madeira), [FEX](https://github.com/FEX-Emu/FEX), [Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt) and [StikDebug](https://github.com/StikDebug/StikDebug).

See [LICENSES](LICENSES) for applicable licenses and attribution. Proprietary components must only be used or redistributed when permitted by their respective licenses.

## Contributing

Issues and pull requests are welcome. Bug reports should include the device model, iOS/iPadOS version, iDeck build, affected game and relevant diagnostic logs. Remove personal information and account credentials before sharing logs.

---

*iDeck is an independent experimental project and is not affiliated with Valve, Microsoft or Apple.*
