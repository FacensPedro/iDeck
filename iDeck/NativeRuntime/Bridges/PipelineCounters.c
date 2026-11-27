#include "PipelineCounters.h"

#include <stdatomic.h>
#include <time.h>

static _Atomic uint64_t stage_calls[IDECK_STAGE_COUNT];
static _Atomic uint64_t stage_bytes[IDECK_STAGE_COUNT];
static _Atomic uint64_t stage_ns[IDECK_STAGE_COUNT];

uint64_t ideck_stage_now(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

void ideck_stage_add(IDeckStage stage, uint64_t bytes, uint64_t start_ns) {
    if ((unsigned)stage >= IDECK_STAGE_COUNT) return;
    const uint64_t now = ideck_stage_now();
    atomic_fetch_add_explicit(&stage_calls[stage], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&stage_bytes[stage], bytes, memory_order_relaxed);
    atomic_fetch_add_explicit(&stage_ns[stage], now > start_ns ? now - start_ns : 0, memory_order_relaxed);
}

IDeckStageTotals ideck_stage_totals(IDeckStage stage) {
    IDeckStageTotals totals = {0, 0, 0};
    if ((unsigned)stage >= IDECK_STAGE_COUNT) return totals;
    totals.calls = atomic_load_explicit(&stage_calls[stage], memory_order_relaxed);
    totals.bytes = atomic_load_explicit(&stage_bytes[stage], memory_order_relaxed);
    totals.nanoseconds = atomic_load_explicit(&stage_ns[stage], memory_order_relaxed);
    return totals;
}
