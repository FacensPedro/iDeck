#include "MadeiraRuntimeBridge.h"
#include <dlfcn.h>
#include <mutex>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <cstdio>

namespace {
std::mutex fex_mutex;
bool fex_initialized = false;

// CS_DEBUGGED/MAP_JIT can remain available after the debugger detaches.
// Madeira's JIT allocator uses BRK #0xf00d and requires a live debugger
// supporting that protocol until its executable pool is prepared.
bool debugger_attached() {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info {};
    size_t size = sizeof(info);
    return sysctl(mib, 4, &info, &size, nullptr, 0) == 0 &&
           size >= sizeof(info) &&
           (info.kp_proc.p_flag & P_TRACED) != 0;
}
}

extern "C" bool ideck_fex_available(void) {
    return dlsym(RTLD_DEFAULT, "fex_initialize") != nullptr;
}

extern "C" bool ideck_fex_jit_ready(void) {
    std::lock_guard<std::mutex> lock(fex_mutex);
    // Once the FEX pool exists, further launches do not need a debugger
    // merely to use that existing RX/RW mapping.
    return fex_initialized || debugger_attached();
}

extern "C" bool ideck_fex_initialize(void) {
    std::lock_guard<std::mutex> lock(fex_mutex);
    if (fex_initialized) return true;

    // Fail without entering jit26_prepare_region: an unhandled BRK is a
    // process-fatal EXC_BREAKPOINT, not a recoverable initialization failure.
    if (!debugger_attached()) {
        std::fprintf(stderr,
            "[iDeck JIT] FEX cannot allocate executable memory: no live debugger "
            "is attached. CS_DEBUGGED or MAP_JIT alone is insufficient. "
            "Attach StikDebug with the Madeira BRK protocol and retry.\n");
        return false;
    }

    using Init = bool (*)(void);
    auto init = reinterpret_cast<Init>(dlsym(RTLD_DEFAULT, "fex_initialize"));
    if (!init) return false;
    fex_initialized = init();
    return fex_initialized;
}
