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

## The split (done in 3.0)

| Original file | Now |
|---|---|
| `SystemCoordinator.swift` (3116 lines) | stored state and status in `SystemCoordinator.swift`; `Application/SystemCoordinator+Diagnostics`, `+JIT`, `+StoreClients`, `+Launch`, `+Dock`, `+SessionEnd` |
| `MainView.swift` (3445 lines) | `MainView` and `WindowsWorkspaceView`; `Presentation/Library/` (artwork, modifiers, home shelves), `Presentation/GameDetails/` (store pages, Steam page, executable page, profile form), `Presentation/Setup/` |
| `WindowsEnvironment.swift` (1231 lines) | launch in `WindowsEnvironment.swift`; `Runtime/WindowsEnvironment+Runtime`, `+Graphics`, `+Profile`, `MadeiraBundleIdentity`, `CompatibilityAuto` |
| `EALibrary.swift` (874 lines) | state in `EALibrary.swift`; `Stores/EA/EALibrary+Account`, `+Downloads`, `+Launch`, `EAInstalledGame`, `EAHashCheck` |
| `UbisoftDownloader.swift` (752 lines) | demux in `UbisoftDownloader.swift`; `Stores/Ubisoft/UbisoftContentClient`, `UbisoftManifest`, `UbisoftInstaller` |

Each part starts with `// Split from <file> (iDeck 3.0 architecture).`; the host tests read
an original file name as the original plus its parts (`tests/host/split_sources.py`).
Members that another part uses lost `private`; the others kept it. Behaviour is unchanged.

| `AutoDLLManager.swift` | the overview in `AutoDLLManager.swift`; `Runtime/AutoDLL/AutoDLLCatalog`, `AutoDLLCache`, `AutoDLLInstaller` |
| `ResourceGovernor.swift` | state and start in `ResourceGovernor.swift`; `Runtime/Resources/ResourceGovernor+Memory`, `+Background` |

Next: view models out of the SwiftUI views.

## iOS system libraries

`scripts/ios_system_libraries.py` keeps the catalog of public iOS frameworks iDeck uses
or may use and writes `docs/ios-system-libraries.md` with the coverage; the host-test
workflow fails when the report is out of date. Frameworks ship with iOS and are never
copied into the IPA; IOKit is not public on iOS and is listed only to be avoided.

## Versions

The project's `MARKETING_VERSION` is the only version: the workflow reads it, the
release request must match it, and the IPA file carries its short form
(`3.0` → `iDeck-3.ipa`).
