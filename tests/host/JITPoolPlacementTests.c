#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "../../iDeck/MadeiraJIT/JITPoolPlacement.h"

int main(void) {
    const uint64_t window = 0x140000000, window_size = 0x8000000;
    /* Reported free run crosses an unreserved executable window. */
    IDeckJITPoolRun low = ideck_jit_pool_run(0x11e4cc000, 768ULL << 20, window, window_size, false);
    IDeckJITPoolRun high = ideck_jit_pool_run(0x11e4cc000, 768ULL << 20, window, window_size, true);
    assert(low.base == 0x11e4cc000 && low.base + low.size == window);
    assert(high.base == window + window_size);
    assert(!ideck_jit_pool_placement_valid(0x11e4cc000, 768ULL << 20, window, window_size));
    assert(ideck_jit_pool_placement_valid(low.base, low.size, window, window_size));
    assert(!ideck_jit_pool_placement_valid(low.base, low.size + 1, window, window_size));
    assert(ideck_jit_pool_placement_valid(0x148000000, 592ULL << 20, window, window_size));
    assert(!ideck_jit_pool_placement_valid(0x7000000000, 768ULL << 20, window, window_size));
    assert(!ideck_jit_pool_placement_valid(0x118ffffff, 1, window, window_size));
    assert(!ideck_jit_pool_placement_valid(0x180000000, 1, window, window_size));
    assert(!ideck_jit_pool_placement_valid(UINT64_MAX - 3, 8, window, window_size));
    assert(!ideck_jit_pool_placement_valid(window, 0, window, window_size));
    assert(ideck_jit_pool_run(window, window_size, window, window_size, false).size == 0);
    assert(ideck_jit_pool_run(window, window_size, window, window_size, true).size == 0);
    /* Enlarged fixed-base EXE windows must also be excluded. */
    assert(!ideck_jit_pool_placement_valid(0x148000000, 64ULL << 20, window, 480ULL << 20));
    assert(ideck_jit_pool_placement_valid(window + (480ULL << 20), 64ULL << 20, window, 480ULL << 20));
    for (uint64_t base = 0x100000000; base < 0x190000000; base += 0x1000000) {
        for (uint64_t size = 0x1000000; size <= 0x40000000; size += 0x1000000) {
            for (int above = 0; above < 2; ++above) {
                IDeckJITPoolRun run = ideck_jit_pool_run(base, size, window, window_size, above);
                if (!run.size) continue;
                assert(run.base >= base && run.base + run.size <= base + size);
                assert(ideck_jit_pool_placement_valid(run.base, run.size, window, window_size));
            }
        }
    }
    puts("PASS: JIT placement, failed reservations, overflow and enlarged EXE windows");
}
