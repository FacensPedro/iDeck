# iOS Memory Management

iDeck includes a **bounded native scratch-buffer manager** intended for host-side temporary allocations. It does not change the physical RAM available to iPadOS, create system swap, bypass the jetsam process limit, or page arbitrary Wine/FEX guest memory to storage.

## Architecture

- `NativeMemoryManager.cpp` provides the thread-safe `ideck_native_memory_*` C API. A single lazy memory pool holds reusable **non-executable** scratch buffers with a configurable active-allocation ceiling and cache ceiling.
- `GuestMemoryPool.cpp` supports reducing its cache limit, immediately freeing least-recently released cached blocks until the new limit is respected.
- `NativeMemoryPressure.mm` listens for UIKit memory-warning and foreground/background notifications and updates the cache policy.
- `iDeckApp.swift` registers notifications at startup. `RuntimeLifecycle.mm` resets the default budgets on native-session preparation and trims scratch cache on session shutdown.
- `NativeMemoryManager.h` exposes the API and usage counters to Swift/C/C++.

## Default policy

The iDeck host sets a **64 MiB active scratch-allocation budget** and an **8 MiB cache limit**. These are conservative policy limits for allocations made **through this API only**; they are **not** the application's process memory limit or the device's RAM size.

| State | Cache limit | Response |
| --- | --- | --- |
| Normal / foreground | Up to 8 MiB | Reuse previously released, compatible buffers |
| Background | Up to 2 MiB | Immediately free cached blocks above the lower limit |
| UIKit memory warning | 0 bytes | Immediately free **all released** scratch buffers; future releases are freed rather than cached |
| Session stop | Existing policy remains | Discard all cached buffers |

The actual retained cache may be much smaller than the limit. A memory-warning event never frees memory that a client is actively using.

## Native API

```cpp
#include "NativeMemoryManager.h"

void perform_host_side_work(size_t bytes) {
    void *buffer = ideck_native_memory_acquire(bytes);
    if (!buffer) return;

    // The buffer is ordinary, uninitialized heap memory.
    // Use it for scratch data only; initialize before reading.

    ideck_native_memory_release(buffer);
}
```

`ideck_native_memory_snapshot` returns active and cached byte counts, allocation counts, configured/effective budgets, pressure events and cache-reclamation totals. `ideck_native_memory_configure` rejects invalid or over-limit budgets. `ideck_native_memory_pressure` can also be called explicitly by a native integration component.

**Caller responsibilities:** release each acquired pointer exactly once; do not share pointers beyond their ownership lifetime; do not use returned memory for JIT executable pages, Metal textures, Wine/FEX guest address spaces, immutable shared data, or app-sandbox-escaping files. Callers must initialize buffer contents before reading. Repeated concurrent calls are internally serialized for memory safety. When the active budget is exhausted, `acquire` returns `nullptr` instead of asking iPadOS for more memory.

## Integration status and limitations

The infrastructure is installed in the iDeck app and responds to memory notifications. The memory manager **only controls scratch buffers allocated through its API**. FEX, Wine, Swift `Data`, Metal textures, system caches and normal `malloc` allocations are unaffected until their owning components explicitly adopt the manager. Avoid substituting this pool for arbitrary FEX allocations: guest memory and executable pages require different ownership, protection and lifetime guarantees.

Reducing cache retention can save memory at the expense of reallocating buffers later. Measure both memory footprint and frame-time variance on a physical iPad before adjusting policy.

## Testing

The `iOS Build` workflow compiles and runs `tests/host/NativeMemoryManagerTests.cpp` to validate budget enforcement, successful reclamation on warning and critical events, preservation of active pointers, double-release rejection, concurrent allocation/release and cache-limit reduction.

On macOS with the Xcode Command Line Tools:

```sh
xcrun clang++ -std=c++20 -O2 -pthread \
  tests/host/NativeMemoryManagerTests.cpp \
  iDeck/NativeRuntime/NativeMemoryManager.cpp \
  iDeck/NativeRuntime/GuestMemoryPool.cpp \
  -o /tmp/ideck-memory-manager-tests

/tmp/ideck-memory-manager-tests
```

Passing these tests verifies the manager's host-side logic, **not** an increase in available RAM, a reduction in measured gameplay memory use, or compatibility with Windows games.
