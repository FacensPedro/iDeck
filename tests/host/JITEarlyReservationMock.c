#include <assert.h>
#include <stdint.h>
#include <stdio.h>
typedef unsigned long vm_address_t;
typedef unsigned long vm_size_t;
typedef unsigned natural_t;
typedef unsigned mach_msg_type_number_t;
typedef int kern_return_t;
typedef int vm_region_submap_info_data_64_t;
typedef int *vm_region_recurse_info_t;
#define KERN_SUCCESS 0
#define KERN_INVALID_ADDRESS 1
#define VM_REGION_SUBMAP_INFO_COUNT_64 1
#define VM_FLAGS_FIXED 0
#define VM_PROT_NONE 0
static vm_address_t madeira_early_pool_base, madeira_early_pool_size;
static vm_address_t starts[4], ends[4];
static int count, query_error, allocation_error, protection_error, released;
static int mach_task_self(void) { return 1; }
static int vm_region_recurse_64(int task, vm_address_t *base, vm_size_t *size,
                               natural_t *depth, int *info, unsigned *n) {
    (void)task; (void)depth; (void)info; (void)n;
    if (query_error) return 99;
    for (int i=0; i<count; ++i) if (ends[i] > *base) {
        *base=starts[i]; *size=ends[i]-starts[i]; return 0;
    }
    return KERN_INVALID_ADDRESS;
}
static int vm_allocate(int task, vm_address_t *base, vm_size_t size, int flags) {
    (void)task; (void)flags;
    assert(*base >= 0x148000000ul && *base + size <= 0x180000000ul);
    for (int i=0; i<count; ++i) assert(*base >= ends[i] || *base+size <= starts[i]);
    return allocation_error;
}
static int vm_protect(int task, vm_address_t a, vm_size_t s, int maximum, int prot) {
    (void)task; (void)a; (void)s; (void)maximum; (void)prot; return protection_error;
}
static int vm_deallocate(int task, vm_address_t a, vm_size_t s) {
    (void)task; (void)a; (void)s; released++; return 0;
}
static void reserve(void) {
    const vm_address_t win=0x140000000ul, winsz=0x8000000ul;
    vm_address_t a=0;
    /* INSERT_PATCH */
}
int main(void) {
    /* The report's 4 MB intruder blocks the old fixed-address placeholder. */
    count=2; starts[0]=0x148000000; ends[0]=0x148400000;
    starts[1]=0x170000000; ends[1]=0x170800000;
    reserve();
    assert(madeira_early_pool_base==ends[0]);
    assert(madeira_early_pool_size==((starts[1]-ends[0]) & ~((16ul<<20)-1)));
    madeira_early_pool_base=madeira_early_pool_size=0;
    query_error=1; reserve(); assert(!madeira_early_pool_base);
    query_error=0; allocation_error=1; reserve(); assert(!madeira_early_pool_base);
    allocation_error=0; protection_error=1; reserve(); assert(!madeira_early_pool_base && released==1);
    protection_error=0; count=1; starts[0]=0x148000000; ends[0]=0x180000000;
    reserve(); assert(!madeira_early_pool_base);
    count=0; reserve(); assert(madeira_early_pool_base==0x148000000);
    assert(madeira_early_pool_size==0x38000000);
    puts("PASS: early JIT fallback skips occupied mappings and handles Mach failures");
}
