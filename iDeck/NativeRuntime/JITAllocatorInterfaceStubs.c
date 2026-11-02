/* Interface-only builds link no Madeira runtime: these stand in for the
 * JITAllocator.c symbols the copied Madeira JIT files (StikJITHelper.swift,
 * EntitlementChecker.swift) reference. Native builds link Madeira's own
 * JITAllocator.c (scripts/link_madeira_native.sh) and compile none of this. */
#if !(defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED)
#include "../MadeiraJIT/JITAllocator.h"
#include <os/proc.h>

unsigned long madeira_early_window_base, madeira_early_window_size;
unsigned long madeira_early_pool_base, madeira_early_pool_size;
unsigned long madeira_early_intruder_base, madeira_early_intruder_size;
unsigned madeira_early_intruder_tag, madeira_early_intruder_prot;

JITRegion *jit_region_create(size_t size) { (void)size; return 0; }
bool jit_make_region_no_footprint(void *addr, size_t size, const char *label) { (void)addr; (void)size; (void)label; return false; }
bool jit_check_debugged(void) { return false; }
void jit_arm_trap_fallback(void) {}
bool jit_cs_status(uint32_t *flags) { if (flags) *flags = 0; return false; }
bool jit_task_map_range(uint64_t *min_address, uint64_t *max_address) {
    if (min_address) *min_address = 0; if (max_address) *max_address = 0; return false;
}
uint64_t jit_available_memory(void) { return (uint64_t)os_proc_available_memory(); }
void *jit26_prepare_region(void *addr, size_t len) { (void)addr; (void)len; return 0; }
void jit26_detach(void) {}
#endif
