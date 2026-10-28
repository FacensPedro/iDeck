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
#include <algorithm>
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
std::atomic<int32_t> wine_pool_last_rx_detail{0};
std::vector<vm_address_t> wine_pool_low_va_pins;
bool wine_pool_frontier_prepared = false;

// Automatic pool selection avoids oversized initial BRK allocations on low-RAM devices.
// An explicit override is honored only for sizes already supported by Madeira.
std::vector<size_t> wine_pool_candidates() {
    constexpr size_t MiB = 1024ULL * 1024;
    constexpr size_t allowed[] = {384, 256, 192, 128, 96, 64};
    size_t preferred = 128;
    uint64_t physical_bytes = 0;
    size_t length = sizeof(physical_bytes);
    if (sysctlbyname("hw.memsize", &physical_bytes, &length, nullptr, 0) == 0 &&
        length == sizeof(physical_bytes)) {
        if (physical_bytes >= 8ULL * 1024 * MiB) preferred = 384;
        else if (physical_bytes >= 6ULL * 1024 * MiB) preferred = 256;
        else if (physical_bytes >= 4ULL * 1024 * MiB) preferred = 192;
        else if (physical_bytes >= 3ULL * 1024 * MiB) preferred = 128;
        else preferred = 96;
    }
    const char *override_text = getenv("IDECK_WINE_JIT_MIB");
    if (override_text && *override_text) {
        char *end = nullptr;
        errno = 0;
        unsigned long value = strtoul(override_text, &end, 10);
        bool valid = errno == 0 && end != override_text && *end == '\\0';
        if (valid) {
            valid = false;
            for (size_t candidate : allowed) {
                if (value == candidate) { valid = true; break; }
            }
        }
        if (valid) preferred = static_cast<size_t>(value);
        else fprintf(stderr, "[iDeck Wine JIT] ignored unsupported IDECK_WINE_JIT_MIB=%s\\n",
                     override_text);
    }
    std::vector<size_t> sizes;
    for (size_t candidate : allowed)
        if (candidate <= preferred) sizes.push_back(candidate * MiB);
    fprintf(stderr, "[iDeck Wine JIT] initial pool preference=%zu MiB; fallback to 64 MiB\\n",
            preferred);
    return sizes;
}

void record_wine_pool_failure(int32_t stage, int32_t mach_code = 0) {
    if (stage >= wine_pool_last_failure.load()) {
        wine_pool_last_mach_code.store(mach_code);
        wine_pool_last_failure.store(stage);
    }
}

// Madeira's FEX dispatcher has a position-dependent RX literal limitation.
// Reserve low virtual pages (not resident memory) to encourage the debugger's
// subsequent executable allocation to land above the known 0x119000000
// frontier. These placeholders are retained for this process lifetime.
void prepare_wine_pool_frontier() {
    if (wine_pool_frontier_prepared) return;
    wine_pool_frontier_prepared = true;
    constexpr vm_size_t chunk = 16ULL * 1024 * 1024;
    for (int i = 0; i < 32; ++i) {
        vm_address_t address = 0;
        kern_return_t kr = vm_allocate(mach_task_self(), &address, chunk, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "[iDeck Wine JIT] low-VA pin stopped kr=%d at chunk %d\n", kr, i);
            break;
        }
        if (address >= 0x119000000ULL) {
            vm_deallocate(mach_task_self(), address, chunk);
            break;
        }
        wine_pool_low_va_pins.push_back(address);
        if (address > UINTPTR_MAX - chunk || address + chunk >= 0x119000000ULL) break;
    }
    fprintf(stderr, "[iDeck Wine JIT] pinned %zu low-VA placeholders before RX allocation\n",
            wine_pool_low_va_pins.size());
}

// A single debugger RX allocation can contain multiple contiguous vm_region
// entries. Reject holes/non-executable subregions, but not valid split regions.
bool executable_mapping(uintptr_t rx, size_t size) {
    const uintptr_t end = rx + size; // acceptable_pool checked overflow
    uintptr_t cursor = rx;
    while (cursor < end) {
        vm_address_t address = static_cast<vm_address_t>(cursor);
        vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t info {};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &region_size,
                                            VM_REGION_BASIC_INFO_64,
                                            reinterpret_cast<vm_region_info_t>(&info),
                                            &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (status != KERN_SUCCESS) {
            wine_pool_last_rx_detail.store(6);
            fprintf(stderr, "[iDeck Wine JIT] vm_region_64 failed at 0x%" PRIxPTR
                            " kr=%d\n", cursor, status);
            return false;
        }
        if (address > cursor || region_size == 0 ||
            address > UINTPTR_MAX - region_size || address + region_size <= cursor) {
            wine_pool_last_rx_detail.store(7);
            return false;
        }
        if ((info.protection & VM_PROT_EXECUTE) == 0) {
            wine_pool_last_rx_detail.store(8);
            fprintf(stderr, "[iDeck Wine JIT] RX page lacks VM_PROT_EXECUTE at 0x%" PRIxPTR
                            " protection=0x%x max=0x%x\n", cursor,
                    info.protection, info.max_protection);
            return false;
        }
        cursor = std::min(end, static_cast<uintptr_t>(address + region_size));
    }
    return true;
}

bool acceptable_pool(uintptr_t address, size_t size) {
    wine_pool_last_rx_detail.store(0);
    if (address < 0x119000000ULL) {
        wine_pool_last_rx_detail.store(1);
        return false;
    }
    if (address > UINTPTR_MAX - size) {
        wine_pool_last_rx_detail.store(2);
        return false;
    }
    const uintptr_t end = address + size;
    // Do not place the JIT mapping inside Wine's PE image window or
    // outside the supported guest/host VM layout.
    if (end > 0x7000000000ULL) {
        wine_pool_last_rx_detail.store(3);
        return false;
    }
    if (address < 0x180000000ULL && end > 0x140000000ULL) {
        wine_pool_last_rx_detail.store(4);
        return false;
    }
    if (address % static_cast<uintptr_t>(vm_page_size) != 0) {
        wine_pool_last_rx_detail.store(5);
        return false;
    }
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

extern "C" int32_t ideck_wine_jit_pool_failure_rx_detail(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
    return wine_pool_last_rx_detail.load();
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
    wine_pool_last_rx_detail.store(0);
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

    prepare_wine_pool_frontier();

    // FEXCore already owns a separate 64 MiB pool. A second 384 MiB RX
    // reservation may fail on iPads with fragmented / restricted virtual
    // address space even when the debugger is correctly attached. Negotiate
    // progressively smaller allocations rather than treating that as a
    // permanent launch failure. Never create a non-executable substitute.
    constexpr size_t MiB = 1024ULL * 1024;
    for (size_t size : wine_pool_candidates()) {
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
            // Never deallocate an unvalidated pointer supplied by an external
            // debugger: it could belong to the app or a Wine PE image.
            // A failed pool attempt is retried at a smaller size instead.
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
            wine_pool_last_rx_detail.store(0);
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
