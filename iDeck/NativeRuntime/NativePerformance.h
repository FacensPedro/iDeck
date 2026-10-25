#ifndef IDECK_NATIVE_PERFORMANCE_H
#define IDECK_NATIVE_PERFORMANCE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*IDeckNativeTask)(void *context);

typedef struct IDeckExecutionScheduler IDeckExecutionScheduler;
IDeckExecutionScheduler *ideck_scheduler_create(size_t workers, size_t queue_capacity);
bool ideck_scheduler_submit(IDeckExecutionScheduler *scheduler, IDeckNativeTask task, void *context);
void ideck_scheduler_wait_idle(IDeckExecutionScheduler *scheduler);
void ideck_scheduler_destroy(IDeckExecutionScheduler *scheduler);
size_t ideck_scheduler_pending(const IDeckExecutionScheduler *scheduler);

typedef struct IDeckGuestMemoryPool IDeckGuestMemoryPool;
typedef struct IDeckMemoryPoolStats {
    size_t active_allocations;
    size_t active_bytes;
    size_t cached_allocations;
    size_t cached_bytes;
} IDeckMemoryPoolStats;
IDeckGuestMemoryPool *ideck_memory_pool_create(size_t max_cached_bytes);
void *ideck_memory_pool_acquire(IDeckGuestMemoryPool *pool, size_t size);
bool ideck_memory_pool_release(IDeckGuestMemoryPool *pool, void *pointer);
bool ideck_memory_pool_stats(const IDeckGuestMemoryPool *pool, IDeckMemoryPoolStats *output);
void ideck_memory_pool_trim(IDeckGuestMemoryPool *pool);
void ideck_memory_pool_destroy(IDeckGuestMemoryPool *pool);

typedef struct IDeckPerformanceSnapshot {
    uint64_t frame_count;
    uint64_t total_frame_time_ns;
    uint64_t peak_frame_time_ns;
    uint64_t swapchain_creations;
} IDeckPerformanceSnapshot;
void ideck_performance_reset(void);
void ideck_performance_record_frame(uint64_t duration_ns);
void ideck_performance_record_swapchain(void);
IDeckPerformanceSnapshot ideck_performance_snapshot(void);

bool ideck_metal_frame_prepare(void *metal_layer);
bool ideck_metal_frame_resize(void *metal_layer, uint32_t pixel_width, uint32_t pixel_height);

#ifdef __cplusplus
}
#endif

#endif
