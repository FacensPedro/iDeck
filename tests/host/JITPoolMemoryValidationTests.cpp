#include <cstdint>
#include <cstddef>
#include <vector>
#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <cstdio>
using mach_vm_address_t = uint64_t;
using mach_vm_size_t = uint64_t;
using mach_msg_type_number_t = unsigned;
using mach_port_t = unsigned;
using kern_return_t = int;
using vm_region_info_t = int *;
struct vm_region_basic_info_data_64_t { int protection; };
constexpr unsigned CTL_KERN=1, KERN_PROC=2, KERN_PROC_PID=3, P_TRACED=4;
struct kinfo_proc { struct { int p_flag; } kp_proc; };
static int sysctl(int *, unsigned, void *, size_t *, void *, size_t) { return -1; }
constexpr unsigned MACH_PORT_NULL=0, VM_REGION_BASIC_INFO_COUNT_64=1, VM_REGION_BASIC_INFO_64=1;
constexpr int KERN_SUCCESS=0, VM_PROT_READ=1, VM_PROT_WRITE=2, VM_PROT_EXECUTE=4;
static uintptr_t vm_page_size=0x1000;
struct Region { uint64_t begin, end; int protection; };
static std::vector<Region> regions;
static unsigned ports_created=0, ports_released=0;
static unsigned mach_task_self() { return 1; }
static int mach_port_deallocate(unsigned, unsigned port) { assert(port==123); ++ports_released; return 0; }
static int mach_vm_region(unsigned, uint64_t *address, uint64_t *size, unsigned, int *info, unsigned *, unsigned *object) {
    for (auto region : regions) {
        if (region.end <= *address) continue;
        *address=region.begin; *size=region.end-region.begin;
        reinterpret_cast<vm_region_basic_info_data_64_t *>(info)->protection=region.protection;
        *object=123; ++ports_created;
        return 0;
    }
    return 1;
}
/* ACTUAL_FEX_RUNTIME */
static void base() {
    for (auto key : {"WINE_IOS_JIT_HOLE", "WINE_IOS_JIT_HOLE2", "WINE_IOS_JIT_TAIL_REGION"}) unsetenv(key);
    setenv("WINE_IOS_JIT_RX","10000",1); setenv("WINE_IOS_JIT_RW","30000",1);
    setenv("WINE_IOS_JIT_SIZE","4000",1);
    regions={{0x10000,0x14000,5},{0x30000,0x34000,3}};
}
int main() {
    base(); assert(ideck_wine_jit_pool_ready());
    auto snap=ideck_jit_snapshot(); assert(snap.rx_executable && snap.rw_writable && snap.wine_pool_prepared);
    setenv("WINE_IOS_JIT_RX","1",1);setenv("WINE_IOS_JIT_RW","1",1);setenv("WINE_IOS_JIT_SIZE","1",1);
    assert(!ideck_wine_jit_pool_ready());
    for (auto bad : {"-10000", "+10000", " 10000", "10000x", "10000000000000000", "0x"}) {
        base();setenv("WINE_IOS_JIT_RX",bad,1);assert(!ideck_wine_jit_pool_ready());
    }
    base();setenv("WINE_IOS_JIT_RW","11000",1);assert(!ideck_wine_jit_pool_ready());
    base();regions[0].protection=1;assert(!ideck_wine_jit_pool_ready());assert(!ideck_jit_snapshot().rx_executable);
    base();regions[0].protection=7;assert(!ideck_wine_jit_pool_ready());
    base();regions[1].protection=1;assert(!ideck_wine_jit_pool_ready());assert(!ideck_jit_snapshot().rw_writable);
    base();regions[1].protection=7;assert(!ideck_wine_jit_pool_ready());
    base();regions[0].end=0x13000;assert(!ideck_wine_jit_pool_ready());
    // RX holes may hold the host stack. Neither RX nor RW needs access there.
    base();regions={{0x10000,0x11000,5},{0x11000,0x12000,3},{0x12000,0x14000,5},
                   {0x30000,0x31000,3},{0x31000,0x32000,0},{0x32000,0x34000,3}};
    assert(!ideck_wine_jit_pool_ready());setenv("WINE_IOS_JIT_HOLE","1000:2000",1);
    assert(ideck_wine_jit_pool_ready());
    for (auto hole : {"0:4000", "1000:5000", "1001:2000", "2000:1000", "bad"}) {
        setenv("WINE_IOS_JIT_HOLE",hole,1);assert(!ideck_wine_jit_pool_ready());
    }
    base();setenv("WINE_IOS_JIT_HOLE","1000:3000",1);setenv("WINE_IOS_JIT_HOLE2","2000:3000",1);
    assert(!ideck_wine_jit_pool_ready());
    base();regions.insert(regions.begin(),{0x8000,0x9000,5});regions.insert(regions.begin()+2,{0x28000,0x29000,3});
    setenv("WINE_IOS_JIT_TAIL_REGION","8000:1000",1);assert(ideck_wine_jit_pool_ready());
    regions[0].protection=1;assert(!ideck_wine_jit_pool_ready());
    assert(ports_created==ports_released);
    puts("PASS: real pool checker rejects fake metadata, map gaps and bad permissions; split holes and tail aliases validated");
}
