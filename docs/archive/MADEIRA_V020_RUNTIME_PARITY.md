# Madeira v0.2.0 runtime comparison (iDeck)

Reference: [Madeira v0.2.0](https://github.com/willfaust/Madeira/releases/tag/v0.2.0),
published 2026-11-04, source commit **5fda6a0e9543e5de1df010aff35748ab913fd0d9**.

iDeck's reproducible native checkout remains
**c2c1b03a9e36ef986c980b9eae3c14d05a372db1**.
Do **not** mix Wine/FEX/DXMT DLLs from different ABI revisions. The
public D3D11 profile must not accidentally include D3D12 dependencies or
the separately licensed Metal Shader Converter.

## Comparing tracked PE folders

I compared the GitHub tree entries in both commits under
app/Madeira/arm64ec-windows and app/Madeira/aarch64-windows.

| Architecture | Pinned entries | v0.2.0 entries | Names added in v0.2.0 |
| --- | ---: | ---: | --- |
| arm64ec-windows | 415 | 416 | EpicGamesLauncher.exe |
| aarch64-windows | 135 | 136 | madeira-galaxy-service.exe |
| i386-windows | 1 (.gitkeep) | 1 (.gitkeep) | None; i386 DLL farm is a build product |

Nine existing PE DLLs differ between the source commits:

- ARM64EC: d3d9.dll, dcomp.dll, kernelbase.dll, sechost.dll,
  d3d12.dll, d3d12core.dll, madeira_d3d12.dll, xtajit64.dll
- AArch64: xtajit.dll

This is a source-tree comparison, **not proof of what is installed on an
individual iPad**. iDeck's native packaging copies whole PE farm folders
from its checkout. An *interface-only* iDeck IPA has no Wine DLL farm.
Native builds can replace/compile additional PE DLLs after checkout.

### Check a real native IPA

Unpack the Madeira 0.2.0 IPA and the newly built **native** iDeck IPA.
Compare the two .app directories:

~~~bash
python3 scripts/audit_madeira_v020_pe.py \
  --madeira-v020 /path/to/Madeira.app \
  --ideck /path/to/iDeck.app \
  --graphics d3d11 \
  --wow64
~~~

The command reports missing names separately from files whose bytes
differ. D3D11 excludes native D3D12 frontends; the i386 farm is included
only if WoW64 is requested. A binary difference is not automatically a
defect: upstream's rebuilt modules are tied to a matching FEX, Wine and DXMT
version.

The six missing Steam-client FFmpeg DLLs and SDL3.dll mentioned in
Fallout: New Vegas diagnostics are **not** part of these Wine PE farm
folders. They belong to the separate Valve client installed into the
Wine prefix, handled by SteamDLLRepair.

## v0.2.0 feature adoption

This change ports **Wine Gecko 2.47.4 cache preparation**:

- Download both upstream-pinned x86 and x86_64 MSIs only from WineHQ
  over HTTPS, automatically on an unmetered and unconstrained network.
- Stream each MSI through SHA-256 verification using the hashes from
  Madeira v0.2.0's WineGecko.swift.
- Stage them under WINEPREFIX/.cache/wine, which the pinned
  WineProcessBridge.m already selects as HOME/.cache/wine; Wine's
  appwiz.cpl can use the MSIs without its in-guest download dialog.
- Never modify an active Wine session, follow a symlink, distribute WineHQ
  binaries inside the IPA, or overwrite an existing backup. Retry failures
  on a later app visit.

Already represented in iDeck in varying degrees: Steam, GOG, Epic,
Steam Cloud, AVX/AVX2, WoW64, MetalFX and controller compatibility.
This does not claim parity with all Madeira v0.2.0 features.

Not yet ported or verified in native iDeck: upstream's updated FEX and
Wine/DXMT PE implementations, EA and itch.io stores, GOG's Galaxy
service, Gecko settings UI, and upstream's other JIT/graphics fixes.
Those require independent source compatibility checks, redistribution
review when applicable, a fully native build and real-device tests.
