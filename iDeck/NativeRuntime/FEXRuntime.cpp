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
#include <string>
#include <limits>
#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace {
std::mutex fex_mutex;
std::atomic<bool> fex_initialized{false};

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
    // Hot JIT-readiness checks must not contend on the FEX initialization mutex.
    // An initialized FEX translator keeps its executable mapping after debugger detach.
    return fex_initialized.load(std::memory_order_acquire) || debugger_attached();
}

extern "C" bool ideck_fex_initialize(void) {
    if (fex_initialized.load(std::memory_order_acquire)) return true;
    std::lock_guard<std::mutex> lock(fex_mutex);
    if (fex_initialized.load(std::memory_order_relaxed)) return true;

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
    const bool initialized = init();
    fex_initialized.store(initialized, std::memory_order_release);
    return initialized;
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
// Reject malformed metadata before querying the task map. Environment values
// describe a layout; they never establish that its pages are executable.
bool pool_hex(const std::string &text, uintptr_t &value) {
    if (text.empty()) return false;
    size_t at = text.size() > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') ? 2 : 0;
    value = 0;
    for (; at < text.size(); ++at) {
        const char c = text[at];
        const unsigned digit = c >= '0' && c <= '9' ? c - '0' :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 16;
        if (digit > 15 || value > (UINTPTR_MAX - digit) / 16) return false;
        value = value * 16 + digit;
    }
    return true;
}

struct PoolRange { uintptr_t begin, end; };
struct PoolState {
    bool rx = false, rw = false;
    size_t span = 0;
    bool ready() const { return rx && rw; }
};

bool pool_pair(const char *name, uintptr_t &first, uintptr_t &second) {
    const char *raw = getenv(name);
    if (!raw || !*raw) return false;
    const std::string text(raw);
    const auto colon = text.find(':');
    return colon != std::string::npos && pool_hex(text.substr(0, colon), first) &&
        pool_hex(text.substr(colon + 1), second);
}

bool pool_permissions(uintptr_t begin, size_t bytes, bool executable) {
    if (!bytes || begin > UINTPTR_MAX - bytes) return false;
    const uintptr_t end = begin + bytes;
    while (begin < end) {
        mach_vm_address_t address = begin;
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info {};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        const kern_return_t kr = mach_vm_region(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (kr != KERN_SUCCESS || address > begin || !size || address > UINTPTR_MAX - size ||
            address + size <= begin) return false;
        const bool allowed = executable
            ? ideck::jit::executable_only(info.protection, VM_PROT_EXECUTE, VM_PROT_WRITE)
            : ideck::jit::writable_only(info.protection, VM_PROT_READ, VM_PROT_WRITE, VM_PROT_EXECUTE);
        if (!allowed) return false;
        begin = std::min<uintptr_t>(end, address + size);
    }
    return true;
}

PoolState wine_pool_state() {
    PoolState state;
    uintptr_t rx = 0, rw = 0, size = 0;
    const auto read = [](const char *name, uintptr_t &value) {
        const char *text = getenv(name);
        return text && pool_hex(text, value);
    };
    if (!read("WINE_IOS_JIT_RX", rx) || !read("WINE_IOS_JIT_RW", rw) ||
        !read("WINE_IOS_JIT_SIZE", size) || !ideck::jit::disjoint(rx, rw, size)) return state;
    const uintptr_t page = vm_page_size;
    if (!page || rx % page || rw % page || size % page) return state;

    std::vector<PoolRange> holes;
    for (const char *key : {"WINE_IOS_JIT_HOLE", "WINE_IOS_JIT_HOLE2"}) {
        const char *text = getenv(key);
        if (!text || !*text) continue;
        uintptr_t off = 0, end = 0;
        if (!pool_pair(key, off, end) || !off || off >= end || end >= size || off % page || end % page)
            return state;
        holes.push_back({off, end});
    }
    std::sort(holes.begin(), holes.end(), [](PoolRange a, PoolRange b) { return a.begin < b.begin; });
    if (holes.size() == 2 && holes[0].end > holes[1].begin) return state;
    std::vector<PoolRange> regions;
    uintptr_t cursor = 0;
    for (const auto hole : holes) {
        if (cursor < hole.begin) regions.push_back({cursor, hole.begin});
        cursor = hole.end;
    }
    regions.push_back({cursor, size});
    state.rx = state.rw = true;
    state.span = size;
    for (const auto region : regions) {
        const size_t bytes = region.end - region.begin;
        state.rx = pool_permissions(rx + region.begin, bytes, true) && state.rx;
        state.rw = pool_permissions(rw + region.begin, bytes, false) && state.rw;
    }
    // Region C is below the primary pool, at the same RX-to-RW distance.
    const char *tail = getenv("WINE_IOS_JIT_TAIL_REGION");
    if (tail && *tail) {
        uintptr_t base = 0, bytes = 0;
        if (!pool_pair("WINE_IOS_JIT_TAIL_REGION", base, bytes) || !base || !bytes ||
            base % page || bytes % page || base >= rx || bytes > rx - base || rw < rx - base)
            return {};
        const uintptr_t alias = rw - (rx - base);
        if (!ideck::jit::disjoint(base, alias, bytes) ||
            !(alias + bytes <= rx || alias >= rx + size) ||
            !(base + bytes <= rw || base >= rw + size)) return {};
        state.rx = pool_permissions(base, bytes, true) && state.rx;
        state.rw = pool_permissions(alias, bytes, false) && state.rw;
    }
    return state;
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
    return wine_pool_state().ready();
}

/// The pool is prepared by StikJITHelper in Swift; nothing is allocated here.
extern "C" bool ideck_wine_jit_pool_prepare(void) {
    return ideck_wine_jit_pool_ready();
}

extern "C" IDeckJITSnapshot ideck_jit_snapshot(void) {
    IDeckJITSnapshot state {};
    state.debugger_attached = debugger_attached();

    if (fex_mutex.try_lock()) {
        state.fex_initialized = fex_initialized.load(std::memory_order_acquire);
        fex_mutex.unlock();
    } else {
        state.fex_state_busy = true;
    }

    const auto pool = wine_pool_state();
    state.wine_pool_prepared = pool.ready();
    state.wine_pool_mib = static_cast<uint32_t>(pool.span / (1024 * 1024));
    state.rx_executable = pool.rx;
    state.rw_writable = pool.rw;
    return state;
}
