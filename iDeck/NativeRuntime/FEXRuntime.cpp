#include "MadeiraRuntimeBridge.h"
#include <dlfcn.h>
#include <mutex>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <cstdio>
#include <initializer_list>
#include <cstdint>
#include <cstdlib>
#include <atomic>

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

    using Init = bool (*)(void);
    auto init = reinterpret_cast<Init>(dlsym(RTLD_DEFAULT, "fex_initialize"));
    if (!init) return false;
    fex_initialized = init();
    return fex_initialized;
}

// Wine's PE/ARM64EC executor uses a separate JIT pool from FEXCore's internal
// 64MB pool. Madeira normally creates it in StikJITHelper before Wine begins.
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <cinttypes>
#include <cstdint>
#include <cstdlib>
#include <cstring>

// Built by the pinned Madeira JITAllocator.c in native-only IPA builds.
// This BRK protocol MUST be serviced by a live, compatible debugger.
extern "C" void *jit26_prepare_region(void *address, size_t size);

namespace {
std::mutex wine_pool_mutex;
uintptr_t wine_pool_rx = 0;
uintptr_t wine_pool_rw = 0;
size_t wine_pool_size = 0;
std::atomic<int32_t> wine_pool_last_failure{0};
std::atomic<int32_t> wine_pool_last_mach_code{0};

void record_wine_pool_failure(int32_t stage, int32_t mach_code = 0) {
    if (stage >= wine_pool_last_failure.load()) {
        wine_pool_last_mach_code.store(mach_code);
        wine_pool_last_failure.store(stage);
    }
}

bool executable_mapping(uintptr_t rx, size_t size) {
    vm_address_t address = static_cast<vm_address_t>(rx);
    vm_size_t region_size = 0;
    vm_region_basic_info_data_64_t info {};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t status = vm_region_64(mach_task_self(), &address, &region_size,
                                        VM_REGION_BASIC_INFO_64,
                                        reinterpret_cast<vm_region_info_t>(&info),
                                        &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    return status == KERN_SUCCESS && address == rx &&
           region_size >= size && (info.protection & VM_PROT_EXECUTE) != 0;
}

bool acceptable_pool(uintptr_t address, size_t size) {
    if (address < 0x119000000ULL || address > UINTPTR_MAX - size) return false;
    uintptr_t end = address + size;
    // Never place host JIT code inside Wine's guest PE address band or
    // the common 0x140000000 executable-image placement window.
    if (end > 0x7000000000ULL) return false;
    if (address < 0x180000000ULL && end > 0x140000000ULL) return false;
    return executable_mapping(address, size);
}

bool export_pool(uintptr_t rx, uintptr_t rw, size_t size) {
    char rx_text[32], rw_text[32], size_text[32];
    snprintf(rx_text, sizeof(rx_text), "%" PRIxPTR, rx);
    snprintf(rw_text, sizeof(rw_text), "%" PRIxPTR, rw);
    snprintf(size_text, sizeof(size_text), "%zx", size);
    if (setenv("WINE_IOS_JIT_RX", rx_text, 1) ||
        setenv("WINE_IOS_JIT_RW", rw_text, 1) ||
        setenv("WINE_IOS_JIT_SIZE", size_text, 1)) {
        unsetenv("WINE_IOS_JIT_RX");
        unsetenv("WINE_IOS_JIT_RW");
        unsetenv("WINE_IOS_JIT_SIZE");
        return false;
    }
    fprintf(stderr, "[iDeck Wine JIT] RX=0x%s RW=0x%s size=0x%s (prepared)\n",
            rx_text, rw_text, size_text);
    return true;
}
}
#endif

extern "C" int32_t ideck_wine_jit_pool_failure_stage(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    return wine_pool_last_failure.load();
#else
    return 0;
#endif
}

extern "C" int32_t ideck_wine_jit_pool_failure_mach_code(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    return wine_pool_last_mach_code.load();
#else
    return 0;
#endif
}

extern "C" bool ideck_wine_jit_pool_ready(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    std::lock_guard<std::mutex> lock(wine_pool_mutex);
    return wine_pool_rx != 0 && wine_pool_rw != 0 && wine_pool_size != 0;
#else
    return false;
#endif
}

extern "C" bool ideck_wine_jit_pool_prepare(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    std::lock_guard<std::mutex> lock(wine_pool_mutex);
    wine_pool_last_failure.store(0);
    wine_pool_last_mach_code.store(0);
    if (wine_pool_rx != 0) {
        if (export_pool(wine_pool_rx, wine_pool_rw, wine_pool_size)) return true;
        record_wine_pool_failure(6);
        return false;
    }
    if (!debugger_attached()) {
        record_wine_pool_failure(1);
        fprintf(stderr, "[iDeck Wine JIT] REFUSED: StikDebug is not attached to this process. "
                        "Enabling JIT once from the app list does not keep the BRK handler attached.\n");
        return false;
    }

    // FEXCore already owns a separate 64 MiB pool. A second 384 MiB RX
    // reservation may fail on iPads with fragmented / restricted virtual
    // address space even when the debugger is correctly attached. Negotiate
    // progressively smaller allocations rather than treating that as a
    // permanent launch failure. Never create a non-executable substitute.
    constexpr size_t MiB = 1024ULL * 1024;
    for (size_t size : {384ULL * MiB, 256ULL * MiB, 192ULL * MiB,
                        128ULL * MiB, 96ULL * MiB, 64ULL * MiB}) {
        // Every jit26_prepare_region call triggers BRK #0xf00d.
        // A detached debugger here would make the call process-fatal.
        if (!debugger_attached()) {
            record_wine_pool_failure(1);
            fprintf(stderr, "[iDeck Wine JIT] debugger detached during pool setup\n");
            return false;
        }
        fprintf(stderr, "[iDeck Wine JIT] requesting %zu MiB RX from StikDebug\n", size / MiB);
        void *result = jit26_prepare_region(nullptr, size);
        const uintptr_t rx = reinterpret_cast<uintptr_t>(result);
        if (rx == 0) {
            record_wine_pool_failure(2);
            fprintf(stderr, "[iDeck Wine JIT] debugger could not allocate %zu MiB RX\n", size / MiB);
            continue;
        }
        if (!acceptable_pool(rx, size)) {
            record_wine_pool_failure(3);
            fprintf(stderr, "[iDeck Wine JIT] rejected RX=0x%" PRIxPTR " size=%zu MiB "
                            "(non-executable or collides with Wine image/guest window)\n",
                    rx, size / MiB);
            vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
            continue;
        }

        // Madeira's 63 GiB (non-extended) map cannot fit the 0x7000000000
        // RW alias hint used on devices with extended virtual addressing.
        // Try a lower, non-guest hint, then a zero hint to let the kernel
        // choose any available alias, without requiring extra entitlements.
        for (vm_address_t hint : {static_cast<vm_address_t>(0x300000000ULL),
                                  static_cast<vm_address_t>(0)}) {
            vm_address_t rw = hint;
            vm_prot_t current = 0, maximum = 0;
            kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0,
                                        VM_FLAGS_ANYWHERE, mach_task_self(),
                                        static_cast<vm_address_t>(rx), FALSE,
                                        &current, &maximum, VM_INHERIT_NONE);
            if (kr != KERN_SUCCESS) {
                record_wine_pool_failure(4, kr);
                fprintf(stderr, "[iDeck Wine JIT] vm_remap failed size=%zu MiB "
                                "hint=0x%lx kr=%d\n", size / MiB,
                        static_cast<unsigned long>(hint), kr);
                continue;
            }

            const uintptr_t alias = static_cast<uintptr_t>(rw);
            const bool overlapping = alias > UINTPTR_MAX - size ||
                (alias < rx + size && alias + size > rx);
            if (overlapping) {
                record_wine_pool_failure(4);
                fprintf(stderr, "[iDeck Wine JIT] rejected overlapping RW alias=0x%lx\n",
                        static_cast<unsigned long>(rw));
                vm_deallocate(mach_task_self(), rw, size);
                continue;
            }
            kr = vm_protect(mach_task_self(), rw, size, FALSE,
                            VM_PROT_READ | VM_PROT_WRITE);
            if (kr != KERN_SUCCESS) {
                record_wine_pool_failure(5, kr);
                fprintf(stderr, "[iDeck Wine JIT] vm_protect(RW) failed size=%zu MiB "
                                "hint=0x%lx kr=%d\n", size / MiB,
                        static_cast<unsigned long>(hint), kr);
                vm_deallocate(mach_task_self(), rw, size);
                continue;
            }

            if (!export_pool(rx, alias, size)) {
                record_wine_pool_failure(6);
                vm_deallocate(mach_task_self(), rw, size);
                vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
                return false;
            }
            wine_pool_rx = rx;
            wine_pool_rw = alias;
            wine_pool_size = size;
            wine_pool_last_failure.store(0);
            wine_pool_last_mach_code.store(0);
            fprintf(stderr, "[iDeck Wine JIT] ready with %zu MiB (RX/RW mirror)\n", size / MiB);
            return true;
        }
        vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
    }

    fprintf(stderr, "[iDeck Wine JIT] FAILED: unable to allocate and dual-map "
                    "even a 64 MiB executable pool. Check StikDebug's in-app "
                    "BRK script, iPadOS memory limit and Wine JIT logs.\n");
    return false;
#else
    return false;
#endif
}
