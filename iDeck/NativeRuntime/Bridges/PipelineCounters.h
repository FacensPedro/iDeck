#ifndef IDECK_PIPELINE_COUNTERS_H
#define IDECK_PIPELINE_COUNTERS_H

/* Benchmark counters for the game-install pipeline (Phase 1 diagnostics).
 * Each stage adds its calls, bytes produced and time spent with relaxed
 * atomics: one clock read on entry and one on exit, nothing else. */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum IDeckStage {
    IDECK_STAGE_DECRYPT = 0,     /* Steam AES chunk decryption */
    IDECK_STAGE_DECOMPRESS = 1,  /* Steam zip/LZMA/zstd and Epic zlib */
    IDECK_STAGE_WRITE = 2,       /* chunk writes to disk */
    IDECK_STAGE_COUNT = 3
} IDeckStage;

typedef struct IDeckStageTotals {
    uint64_t calls;
    uint64_t bytes;
    uint64_t nanoseconds;
} IDeckStageTotals;

/* Monotonic nanoseconds (CLOCK_UPTIME_RAW). */
uint64_t ideck_stage_now(void);
/* Records one call that started at `start_ns` and produced `bytes`. */
void ideck_stage_add(IDeckStage stage, uint64_t bytes, uint64_t start_ns);
IDeckStageTotals ideck_stage_totals(IDeckStage stage);

#ifdef __cplusplus
}
#endif

#endif
