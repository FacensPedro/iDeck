#ifndef IDECK_NATIVE_MEMORY_MANAGER_H
#define IDECK_NATIVE_MEMORY_MANAGER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum IDeckMemoryPressure {
    IDECK_MEMORY_PRESSURE_NORMAL = 0,
    IDECK_MEMORY_PRESSURE_WARNING = 1,
    IDECK_MEMORY_PRESSURE_CRITICAL = 2
} IDeckMemoryPressure;

typedef struct IDeckNativeMemoryStats {
    size_t active_allocations;
    size_t active_bytes;
    size_t cached_allocations;
    size_t cached_bytes;
    size_t active_budget_bytes;
    size_t configured_cache_budget_bytes;
    size_t effective_cache_budget_bytes;
    uint64_t pressure_events;
    uint64_t reclaimed_cached_bytes;
    uint32_t pressure_level;
} IDeckNativeMemoryStats;

bool ideck_native_memory_configure(size_t active_budget_bytes, size_t cache_budget_bytes);
void *ideck_native_memory_acquire(size_t bytes);
bool ideck_native_memory_release(void *pointer);
bool ideck_native_memory_snapshot(IDeckNativeMemoryStats *output);
void ideck_native_memory_pressure(IDeckMemoryPressure pressure);
void ideck_native_memory_trim(void);
void ideck_native_memory_install_notifications(void);

#ifdef __cplusplus
}
#endif
#endif
