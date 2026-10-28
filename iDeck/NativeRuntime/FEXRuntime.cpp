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
    if (wine_pool_rx != 0) return export_pool(wine_pool_rx, wine_pool_rw, wine_pool_size);
    if (!debugger_attached()) {
        fprintf(stderr, "[iDeck Wine JIT] REFUSED: no live debugger for executable pool\n");
        return false;
    }

    // Deliberately conservative baseline. Madeira uses larger, profile-aware
    // pools and sophisticated address-space placement for demanding games.
    // Keep any failed attempt bounded; never start Wine without the pool.
    for (size_t size : {384ULL * 1024 * 1024, 256ULL * 1024 * 1024}) {
        void *result = jit26_prepare_region(nullptr, size);
        uintptr_t rx = reinterpret_cast<uintptr_t>(result);
        if (rx == 0 || !acceptable_pool(rx, size)) {
            fprintf(stderr, "[iDeck Wine JIT] rejected RX=0x%" PRIxPTR " size=%zu\n", rx, size);
            if (rx != 0) vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
            continue;
        }

        vm_address_t rw = 0;
        vm_prot_t current = 0, maximum = 0;
        kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0,
                                    VM_FLAGS_ANYWHERE, mach_task_self(),
                                    static_cast<vm_address_t>(rx), FALSE,
                                    &current, &maximum, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "[iDeck Wine JIT] vm_remap(RW) failed kr=%d\n", kr);
            vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
            continue;
        }

        kr = vm_protect(mach_task_self(), rw, size, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS ||
            (static_cast<uintptr_t>(rw) < rx + size &&
             static_cast<uintptr_t>(rw) + size > rx)) {
            fprintf(stderr, "[iDeck Wine JIT] RW alias invalid/protection failed kr=%d\n", kr);
            vm_deallocate(mach_task_self(), rw, size);
            vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
            continue;
        }

        if (!export_pool(rx, static_cast<uintptr_t>(rw), size)) {
            vm_deallocate(mach_task_self(), rw, size);
            vm_deallocate(mach_task_self(), static_cast<vm_address_t>(rx), size);
            return false;
        }
        wine_pool_rx = rx;
        wine_pool_rw = static_cast<uintptr_t>(rw);
        wine_pool_size = size;
        return true;
    }

    fprintf(stderr, "[iDeck Wine JIT] FAILED: no valid RX/RW pool; Wine launch cancelled\n");
    return false;
#else
    return false;
#endif
}
