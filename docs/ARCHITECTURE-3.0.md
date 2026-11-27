# iDeck 3.0 architecture plan

This document sets the target layout for iDeck 3 and records what each release moves
into it. Every step keeps the app building and the host tests green; large files are
split by moving whole extensions, one file per pull request, so a regression points to
one change.

## Layers

| Layer | Holds | Talks to |
|---|---|---|
| Presentation | SwiftUI views and their view models (`MainView`, `SettingsView`, game pages) | Application |
| Application | Session lifecycle, launch flow, downloads queue, recovery (`Application/`) | Domain, Stores, Runtime |
| Domain | Games, profiles, recommendations, languages, compatibility records | nothing below |
| Stores | Steam, GOG, Epic, EA, Ubisoft: sign-in, library, downloads, launch arguments | Domain, Runtime |
| Runtime | Wine prefix, environment, Virtual Swap, Auto DLL Manager, JIT preparation (Swift) | NativeRuntime |
| NativeRuntime | Madeira: Wine ARM64EC, WoW64, FEX, wineserver, DXMT, madeira-d3d12 (C/C++/ObjC) | iOS |

Swift reaches the native runtime only through the C functions declared in the bridging
header (`ideck_*`, `wine_*`, `madeira_*`); no Swift type crosses into C++.

## Session lifecycle (3.0)

`Application/SessionLifecycle.swift` is the one state machine for a Windows session:
`idle → preparing → launching → running → closing → idle`, with `failed` and
`recovering` reachable from any active state. `SystemCoordinator.setWindowsStatus`
reports every status to it; transitions it does not allow are logged and ignored, and
the last ones go into the bug report.

## Order of the split (from 3.0 on)

1. `SystemCoordinator.swift`: JIT preparation, Steam launch, Dock launch, session end
   (one file each, as extensions).
2. `MainView.swift`: one file per store's game page, the library shelves, the session screen.
3. `WindowsEnvironment.swift`: graphics config, game profile environment, launch.
4. `EALibrary.swift`, `UbisoftDownloader.swift`: sign-in, library, download, licence.
5. `AutoDLLManager`, `ResourceGovernor`: catalog/cache/install and memory/background parts.

## iOS system libraries

`scripts/ios_system_libraries.py` keeps the catalog of public iOS frameworks iDeck uses
or may use and writes `docs/ios-system-libraries.md` with the coverage; the host-test
workflow fails when the report is out of date. Frameworks ship with iOS and are never
copied into the IPA; IOKit is not public on iOS and is listed only to be avoided.

## Versions

The project's `MARKETING_VERSION` is the only version: the workflow reads it, the
release request must match it, and the IPA file carries its short form
(`3.0.0` → `iDeck-3.ipa`).
