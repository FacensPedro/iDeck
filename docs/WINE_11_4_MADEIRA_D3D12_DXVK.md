# Wine 11.4, Madeira native D3D12 and automatic DXVK HUD

## Existing native runtime

The pinned Madeira revision is `fd9f2f3d0434a4116e4c3351f286a0fc376b4e36`.
Its `wine` submodule points to `willfaust/wine` commit
`9129e9684daaeae70da9435e7c6060e59392634e`, whose `VERSION`
file contains **Wine version 11.4**. This is an iOS/ARM64EC-specific fork;
substituting generic Wine 11.4 sources would remove necessary Madeira integration.

`scripts/fetch_madeira_sources.sh` and
`scripts/build_madeira_components.sh` now fail immediately if the pinned
checkout has a different Wine version. All native FEX, Wine Unix,
ARM64EC Windows and WineMetal archives remain compiled from the pinned
Madeira sources.

## Native Direct3D 12

The pinned Madeira source already includes a real native
`madeira-d3d12` implementation. Its
`build/madeira-d3d12/build-pe.sh` generates:

- `madeira_d3d12.dll`: native ARM64EC Direct3D 12-to-Metal frontend.
- `d3d12.dll`: an identical copy exposed under Windows' standard DLL name.
- `d3d12core.dll`: the optional Agility SDK frontend.

D3D12 shaders require Madeira's Metal Shader Converter library.
The existing `scripts/build_madeira_components.sh` performs the
native D3D12 build and now verifies that the standard loader is the
same binary as the Madeira frontend. The IPA packaging step and
`scripts/verify_madeira_bundle.py` check both top-level and
`MadeiraRuntime` copies; a mismatched loader fails the native IPA build.

The application now checks `madeira_d3d12.dll` explicitly in addition
to `d3d12.dll` and `d3d12core.dll`. A prebuilt native kit is accepted
only when its metadata declares Wine 11.4 and Madeira D3D12, contains
all three DLLs, and has matching frontend hashes. Existing kits without
these checks must be rebuilt.

## Automatic DXVK HUD

On each Windows game configuration, iDeck sets
`DXVK_HUD=devinfo,fps` unless an external configuration already supplies
a value. DXVK itself controls whether it renders an overlay; the setting
does not load DXVK or detect Direct3D APIs ahead of time.
A game using DXMT, WineD3D or Madeira native D3D12 will not display a
DXVK overlay merely because the variable exists.

The independent **Metal diagnostics HUD** toggle controls only
`MTL_HUD_ENABLED`; it remains opt-in. The separate iDeck FPS/CPU/Metal
memory overlay stays disabled by default.

The bundle has a Wine-provided Vulkan stub and DXMT's native Metal
backend, **not a working native Vulkan driver with DXVK preinstalled**.
Consequently, automatic HUD configuration does not imply DXVK can
render on every iPad. Supplying DXVK and a compatible Vulkan
implementation is a separate runtime integration.

## Testing

Host regression tests:

```bash
python3 -m unittest discover -s tests/host -p 'test_wine_11_4_d3d12_dxvk_hud.py' -v
python3 -m unittest discover -s tests/host -p 'test_madeira_native_kit.py' -v
python3 -m unittest discover -s tests/host -p 'test_madeira_bundle.py' -v
```

The iOS Build workflow also runs the compiled
`GraphicsOverrideTests.swift` and packages an unsigned IPA.
**Only a licensed native build** with the Metal Shader Converter can
claim inclusion of Wine/FEX/DXMT/native D3D12; interface-only IPAs do
not contain those binaries. Device tests are still necessary for
game launch, DXIL conversion and Metal presentation.
