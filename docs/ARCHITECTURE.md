# iDeck architecture

iDeck has three layers. Each layer calls only the one below it; Madeira's own
FEX, Wine ARM64EC, DXMT and D3D12 do the translation and rendering and are
linked statically into the app (`MadeiraStaticABI.h`).

| Layer | Language | Location | Owns |
| --- | --- | --- | --- |
| 1. iDeck UI | SwiftUI | `iDeck/*.swift` | Library, stores (Steam, GOG, Epic, EA app, Ubisoft Connect), settings, downloads, iRelay service, game session screen |
| 2. Runtime Manager | Swift + Objective-C++ | `SystemCoordinator.swift`, `WindowsEnvironment.swift`, `ResourceGovernor.swift`, `NativeSymbol.swift`, `MadeiraDock/`, `MadeiraJIT/`, `NativeRuntime/MadeiraRuntimeBridge.mm`, `NativeRuntime/WineBridge.mm` | Prefix, Wine and wineserver start/stop, JIT (StikDebug, 896 MB pool by default), session state and errors, memory pressure |
| 3. Madeira Core | C/C++ (+ the linked Madeira archives) | `NativeRuntime/` | FEX/JIT guards, graphics availability (DXMT, D3D12, Metal), controllers, Visual C++ extraction, Wine log triage |

## Layer 1 — iDeck UI

- Nothing heavy runs on the main thread: library scans, manifest parsing and
  extraction use detached tasks or background queues.
- The game session screen (`GameSessionView.swift`) samples once a second and
  publishes only what it shows, only when it changes (`GameRuntimeMetrics`).
  FPS, CPU and Metal memory are measured only while the performance overlay is on.
- The 5-second JIT status probe (`MainView`) pauses while a Wine game runs:
  JIT cannot change under a running game.
- iRelay transfers (`IRelayDeviceService`) run on a `.utility` queue so SHA-1
  checks and file writes stay below the game's threads.

## Layer 2 — Runtime Manager

- `SystemCoordinator` is the single owner of a session: prefix preparation,
  Visual C++/Gecko/Mono components, JIT, launch, close and session state.
- `WindowsEnvironment` builds the launch request and calls
  `ideck_madeira_launch_v1` (`MadeiraRuntimeBridge.mm`) once per launch.
- `WineBridge.mm` wraps Wine's process and wineserver entry points
  (`ideck_wineprocess_*`, `ideck_wineserver_*`).
- `NativeSymbol` resolves Madeira's C entry points (`winios_*`, `madeira_*`)
  once and caches them, instead of a `dlsym` on every frame-layout or
  per-second call.
- `ResourceGovernor` is the one memory-pressure handler: on a warning it drops
  what iDeck can rebuild (network and artwork caches) and logs the footprint;
  it also pauses games in the background and holds 120 Hz only during play.

## Layer 3 — Madeira Core (`iDeck/NativeRuntime`)

| File | Contents |
| --- | --- |
| `MadeiraRuntimeBridge.h/.mm` | Launch ABI (`ideck_madeira_launch_v1`), runtime preparation, session completion |
| `WineBridge.mm` | Wine guest process and wineserver control |
| `FEXRuntime.cpp`, `JITRegionPolicy.h` | FEX availability, Wine JIT pool state and failure details |
| `MadeiraPlatform.mm` | Metal, DXMT and D3D12 availability; end of session |
| `DirectInputBridge.mm`, `GamepadResponse.h` | Controllers, XInput/HID, touch gamepad |
| `VCArchiveExtractor.c` | Visual C++ cabinet extraction and PE checks |
| `WineLogTriage.c` | Wine log diagnosis |
| `MadeiraHostCallbacks.m` | Host log sink (kept out of the native static archive) |
| `InterfaceOnlyStubs.c` | JIT allocator and Dock stand-ins for interface-only builds |
| `RuntimeSupport.h`, `MadeiraStaticABI.h`, `WindowsPEMachine.h` | C declarations shared with Swift and the linked Madeira ABI |

Executable memory is only ever created by Madeira's JIT allocator under
StikDebug; iDeck's own code allocates no RX pages.

## Vendored Madeira (`iDeck/Vendor/Madeira`)

`MadeiraDock.swift`, `DockInstallers.swift`, `DockReset.swift`,
`DockStartProgram.swift` and `SteamRuntime.swift` are copied unchanged from
the Madeira commit pinned in `scripts/fetch_madeira_sources.sh`. Updating
Madeira means replacing these files. iDeck's additions around them (Steam DLL
repair, Steam video libraries, external drives) live in
`iDeck/MadeiraDock/IDeckDockGlue.swift`.

## Tests and CI

- `tests/host/`: `python3 -m unittest discover -s tests/host`;
  `tests/host/support.py` provides `ROOT` and cached `repo_text()`.
- `.github/workflows/host-tests.yml`: the whole host suite on every push/PR.
- `.github/workflows/ios.yml`: interface IPA on pushes and PRs; native IPA
  (FEX, Wine, DXMT, D3D12) on manual runs; releases only from a verified
  native IPA.
- `docs/PERFORMANCE_1_1.md`: what 1.1 changed and what needs an iPad to verify.
- `docs/archive/`: dated reports from earlier integration stages.
