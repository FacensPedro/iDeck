# iDeck architecture

iDeck is split into three layers. Each layer only calls the one below it.

| Layer | Location | Role |
| --- | --- | --- |
| Interface | `iDeck/*.swift` (SwiftUI) | Library, stores (Steam, Epic, GOG, EA app, Ubisoft Connect), settings, iRelay USB service |
| Coordination | `iDeck/SystemCoordinator.swift`, `iDeck/MadeiraDock/`, `iDeck/MadeiraJIT/` | Wine prefixes, Dock installers, JIT, session start/stop |
| Madeira core | `iDeck/NativeRuntime/` | C/C++/Objective-C++ bridge to FEX, Wine, DXMT and D3D12 |

## Madeira core (`iDeck/NativeRuntime`)

| File | Contents |
| --- | --- |
| `MadeiraCore.cpp` | JIT and FEX memory, runtime error reporting, Windows path mapping, D3D12 canary |
| `MadeiraPlatform.mm` | Metal renderer/swapchain/frames, DXMT availability, audio session, memory-pressure notifications, session lifecycle |
| `NativePerformance.cpp` | Frame clock and lock-free performance counters |
| `NativeMemoryManager.cpp`, `GuestMemoryPool.cpp` | Guest memory budget and reusable pools |
| `FEXRuntime.cpp`, `FEXExecutionScheduler.cpp` | FEX start-up and execution scheduling |
| `MadeiraRuntimeBridge.mm`, `WineProcessBridge.mm`, `WineServerBridge.m` | Wine process and wineserver control |
| `DirectInputBridge.mm` | Controllers, XInput/HID and touch gamepad |
| `VCArchiveExtractor.c`, `WineLogTriage.c` | Visual C++ cabinet extraction and Wine log triage |
| `MadeiraHostCallbacks.m` | Host log sink (kept out of the native static archive) |
| `*InterfaceStubs.c` | Stand-ins compiled only in interface-only builds |

Public C entry points are declared in `RuntimeSupport.h`, `MadeiraRuntimeBridge.h`,
`NativePerformance.h` and `NativeMemoryManager.h`; the statically linked Madeira
ABI is in `MadeiraStaticABI.h`.
