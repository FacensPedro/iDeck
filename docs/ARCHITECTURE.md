# iDeck architecture

iDeck is split into three layers. Each layer only calls the one below it.

| Layer | Location | Role |
| --- | --- | --- |
| Interface | `iDeck/*.swift` (SwiftUI) | Library, stores (Steam, Epic, GOG, EA app, Ubisoft Connect), settings, iRelay USB service |
| Coordination | `iDeck/SystemCoordinator.swift`, `iDeck/MadeiraDock/` (glue), `iDeck/MadeiraJIT/` | Wine prefixes, Dock installers, JIT, session start/stop |
| Vendored Madeira | `iDeck/Vendor/Madeira/` | Madeira's Dock and Steam runtime files, byte-for-byte from the pinned commit; never edited |
| Madeira core | `iDeck/NativeRuntime/` | C/C++/Objective-C++ bridge to FEX, Wine, DXMT and D3D12 |

## Madeira core (`iDeck/NativeRuntime`)

| File | Contents |
| --- | --- |
| `MadeiraCore.cpp` | JIT and FEX memory, runtime error reporting, Windows path mapping, D3D12 canary |
| `MadeiraPlatform.mm` | Shared Metal device, renderer/swapchain/frames, DXMT availability, audio session, memory-pressure notifications, session lifecycle |
| `NativePerformance.cpp` | Frame clock and lock-free performance counters |
| `NativeMemoryManager.cpp`, `GuestMemoryPool.cpp` | Guest memory budget and reusable pools |
| `FEXRuntime.cpp`, `FEXExecutionScheduler.cpp` | FEX start-up and execution scheduling |
| `MadeiraRuntimeBridge.mm`, `WineBridge.mm` | Wine process and wineserver control |
| `DirectInputBridge.mm` | Controllers, XInput/HID and touch gamepad |
| `VCArchiveExtractor.c`, `WineLogTriage.c` | Visual C++ cabinet extraction and Wine log triage |
| `MadeiraHostCallbacks.m` | Host log sink (kept out of the native static archive) |
| `InterfaceOnlyStubs.c` | JIT allocator and Dock stand-ins compiled only in interface-only builds |

Public C entry points are declared in `RuntimeSupport.h`, `MadeiraRuntimeBridge.h`,
`NativePerformance.h` and `NativeMemoryManager.h`; the statically linked Madeira
ABI is in `MadeiraStaticABI.h`.

## Vendored Madeira (`iDeck/Vendor/Madeira`)

`MadeiraDock.swift`, `DockInstallers.swift`, `DockReset.swift`,
`DockStartProgram.swift` and `SteamRuntime.swift` are copied unchanged from
the Madeira commit pinned in `scripts/fetch_madeira_sources.sh`. Updating
Madeira means replacing these files. Everything iDeck adds around them
(Steam DLL repair, Steam video libraries, external drives) lives in
`iDeck/MadeiraDock/IDeckDockGlue.swift`.

## Tests and CI

- `tests/host/`: run with `python3 -m unittest discover -s tests/host`;
  `tests/host/support.py` provides `ROOT` and cached `repo_text()`.
- `.github/workflows/host-tests.yml`: the whole host suite on every push/PR.
- `.github/workflows/ios.yml`: interface IPA, native IPA, macOS-only tests
  and releases.
- `docs/archive/`: dated reports from earlier integration stages.
