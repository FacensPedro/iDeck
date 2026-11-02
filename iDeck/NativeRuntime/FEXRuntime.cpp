#include "MadeiraStaticABI.h"
#include "MadeiraRuntimeBridge.h"
#include "JITRegionPolicy.h"
#include <mutex>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <cstdio>
#include <initializer_list>
#include <cstdint>
#include <cstdlib>
#include <atomic>
#include <algorithm>
#include <functional>
#include <vector>

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
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    // The native build must resolve this strong symbol during final linking.
    return &fex_initialize != nullptr;
#else
    return false;
#endif
}

extern "C" bool ideck_jit_debugger_attached(void) {
    return debugger_attached();
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

#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    // The native initializer must be resolved from the real linked FEX bridge.
    using Init = bool (*)(void);
    Init init = &fex_initialize;
    fex_initialized = init();
    return fex_initialized;
#else
    return false;
#endif
}

// Wine's JIT pool is Madeira's: StikJITHelper.allocatePool (copied verbatim
// into iDeck/MadeiraJIT) takes it from the debugger and the app exports
// WINE_IOS_JIT_RX / _RW / _SIZE (and the hole/tail regions) before Wine
// starts, exactly as Madeira's ContentView does. iDeck's own pool code is gone;
// this side only reads what was exported.
namespace {
uintptr_t exported_pool_value(const char *name) {
    const char *text = getenv(name);
    if (!text || !*text) return 0;
    char *end = nullptr;
    const unsigned long long value = strtoull(text, &end, 16);
    return (end && *end == '\0') ? static_cast<uintptr_t>(value) : 0;
}
}

extern "C" int32_t ideck_wine_jit_pool_failure_stage(void) {
    // The pool is allocated by StikJITHelper at launch; a pool not prepared yet
    // is not a failure (its real reason is StikJITHelper.poolFailure).
    return 0;
}

extern "C" int32_t ideck_wine_jit_pool_failure_rx_detail(void) { return 0; }

extern "C" int32_t ideck_wine_jit_pool_failure_mach_code(void) { return 0; }

extern "C" bool ideck_wine_jit_pool_ready(void) {
    return exported_pool_value("WINE_IOS_JIT_RX") != 0 &&
           exported_pool_value("WINE_IOS_JIT_RW") != 0 &&
           exported_pool_value("WINE_IOS_JIT_SIZE") != 0;
}

/// The pool is prepared by StikJITHelper in Swift; nothing is allocated here.
extern "C" bool ideck_wine_jit_pool_prepare(void) {
    return ideck_wine_jit_pool_ready();
}

extern "C" IDeckJITSnapshot ideck_jit_snapshot(void) {
    IDeckJITSnapshot state {};
    state.debugger_attached = debugger_attached();

    if (fex_mutex.try_lock()) {
        state.fex_initialized = fex_initialized;
        fex_mutex.unlock();
    } else {
        state.fex_state_busy = true;
    }

    state.wine_pool_prepared = ideck_wine_jit_pool_ready();
    if (state.wine_pool_prepared) {
        state.wine_pool_mib = static_cast<uint32_t>(exported_pool_value("WINE_IOS_JIT_SIZE") / (1024 * 1024));
        state.rx_executable = true;
        state.rw_writable = true;
    }
    return state;
}
