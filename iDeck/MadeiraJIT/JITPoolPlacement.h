#ifndef IDECK_JIT_POOL_PLACEMENT_H
#define IDECK_JIT_POOL_PLACEMENT_H
#include <stdint.h>
#include <stdbool.h>

typedef struct { uint64_t base, size; } IDeckJITPoolRun;

/* Intersect a free VM run with one side of the executable window. The
 * window is excluded even when its early Mach reservation failed. */
static inline IDeckJITPoolRun ideck_jit_pool_run(uint64_t base, uint64_t size,
                                               uint64_t window, uint64_t window_size,
                                               bool above) {
    IDeckJITPoolRun empty = {0, 0};
    const uint64_t floor = UINT64_C(0x119000000);
    const uint64_t ceiling = UINT64_C(0x180000000);
    if (!size || base > UINT64_MAX - size ||
        !window_size || window > UINT64_MAX - window_size) return empty;
    uint64_t lo = base > floor ? base : floor;
    uint64_t hi = base + size < ceiling ? base + size : ceiling;
    if (above) {
        if (lo < window + window_size) lo = window + window_size;
    } else if (hi > window) hi = window;
    if (lo >= hi) return empty;
    IDeckJITPoolRun result = {lo, hi - lo};
    return result;
}

static inline bool ideck_jit_pool_placement_valid(uint64_t base, uint64_t size,
                                                  uint64_t window, uint64_t window_size) {
    IDeckJITPoolRun below = ideck_jit_pool_run(base, size, window, window_size, false);
    IDeckJITPoolRun above = ideck_jit_pool_run(base, size, window, window_size, true);
    return size && ((below.base == base && below.size == size) ||
                    (above.base == base && above.size == size));
}
#endif
