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

## Views and view models (3.0)

Files that held both a screen and the object behind it now hold one of them:

| File | View (Presentation/) | Model |
|---|---|---|
| `BugReportView.swift` (logs, scanners) | `BugReport/BugReportScreen.swift` (`BugReportView`) | `BugReport/BugReportModel.swift` |
| `EpicCloud.swift` (`EpicCloud`, `EpicCloudSetting`) | `Epic/EpicCloudViews.swift` | stays in `EpicCloud.swift` |
| `ExternalDrives.swift` (`ExternalDrives`) | `Settings/ExternalDrivesSettingsView.swift` | stays in `ExternalDrives.swift` |
| `GOGLibrary.swift` (API, tokens, scanner) | `GOG/GOGSignInView.swift` | `Stores/GOG/GOGLibraryModel.swift` |

The store libraries (`SteamOwnedGamesModel`, `EpicLibrary`, `EALibrary`, `UbisoftLibrary`,
`GOGLibraryModel`) are the views' models: views observe them and call their methods, and
keep only presentation state (`@State`) themselves.

Settings (3.0): `SettingsView.swift` keeps the screen's state and its overview; the pages
are in `Presentation/Settings/SettingsView+Stores` (Steam, GOG, Epic, EA, Ubisoft),
`+System` (JIT, controls, graphics, storage, runtime, memory) and `+General` (language,
updates, shared rows); the shared rows in `SettingsComponents.swift`; the Ubisoft account
(saved login, sign-in web view, session) in `Stores/Ubisoft/UbisoftAccount.swift`.

Game pages (3.0): one file per page in `Presentation/GameDetails/`: the shared
`StoreGameDetailsView`, `GOGGameDetailsSheet`, `EAGameDetailsSheet`,
`UbisoftGameDetailsSheet`, `EpicGameDetailsSheet`, `WindowsExecutableDetailsView`, and the
Steam page as `SteamProgramDetailsView` (header, actions, settings) plus
`SteamProgramDetailsView+Sections` (size, Steam Cloud saves, download status, DLCs).
Each page observes its store's library as its model.

## iOS system libraries

`scripts/ios_system_libraries.py` keeps the catalog of public iOS frameworks iDeck uses
or may use and writes `docs/ios-system-libraries.md` with the coverage; the host-test
workflow fails when the report is out of date. Frameworks ship with iOS and are never
copied into the IPA; IOKit is not public on iOS and is listed only to be avoided.

## Versions

The project's `MARKETING_VERSION` is the only version: the workflow reads it, the
release request must match it, and the IPA file carries its short form
(`3.0` → `iDeck-3.ipa`).
