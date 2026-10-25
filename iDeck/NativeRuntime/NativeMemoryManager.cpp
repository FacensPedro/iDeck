#include "NativeMemoryManager.h"
#include "NativePerformance.h"

#include <limits>
#include <mutex>
#include <new>

namespace {
constexpr size_t MiB = 1024u * 1024u;
constexpr size_t DefaultActiveBudget = 64u * MiB;
constexpr size_t DefaultCacheBudget = 8u * MiB;
constexpr size_t MaxActiveBudget = 512u * MiB;

struct MemoryState {
    std::mutex mutex;
    IDeckGuestMemoryPool *pool = nullptr;
    size_t active_budget = DefaultActiveBudget;
    size_t configured_cache_budget = DefaultCacheBudget;
    size_t effective_cache_budget = DefaultCacheBudget;
    uint64_t pressure_events = 0;
    uint64_t reclaimed_bytes = 0;
    uint32_t pressure_level = IDECK_MEMORY_PRESSURE_NORMAL;
};

MemoryState &state() {
    static MemoryState instance;
    return instance;
}

bool ensure_pool(MemoryState &s) {
    if (s.pool) return true;
    s.pool = ideck_memory_pool_create(s.effective_cache_budget);
    return s.pool != nullptr;
}

IDeckMemoryPoolStats pool_stats(MemoryState &s) {
    IDeckMemoryPoolStats stats{};
    if (s.pool) ideck_memory_pool_stats(s.pool, &stats);
    return stats;
}

void reclaim_cache(MemoryState &s, size_t limit) {
    if (!s.pool) return;
    size_t before = pool_stats(s).cached_bytes;
    ideck_memory_pool_set_cache_limit(s.pool, limit);
    size_t after = pool_stats(s).cached_bytes;
    if (before > after) s.reclaimed_bytes += static_cast<uint64_t>(before - after);
}
}

extern "C" bool ideck_native_memory_configure(size_t active_budget_bytes, size_t cache_budget_bytes) {
    if (!active_budget_bytes || active_budget_bytes > MaxActiveBudget ||
        cache_budget_bytes > active_budget_bytes) return false;
    MemoryState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    if (pool_stats(s).active_bytes > active_budget_bytes) return false;
    s.active_budget = active_budget_bytes;
    s.configured_cache_budget = cache_budget_bytes;
    size_t effective = s.pressure_level == IDECK_MEMORY_PRESSURE_CRITICAL
        ? 0
        : (s.pressure_level == IDECK_MEMORY_PRESSURE_WARNING ? cache_budget_bytes / 4 : cache_budget_bytes);
    s.effective_cache_budget = effective;
    reclaim_cache(s, effective);
    return true;
}

extern "C" void *ideck_native_memory_acquire(size_t bytes) {
    if (!bytes) return nullptr;
    MemoryState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    auto before = pool_stats(s);
    if (bytes > s.active_budget || before.active_bytes > s.active_budget - bytes) return nullptr;
    if (!ensure_pool(s)) return nullptr;
    void *memory = ideck_memory_pool_acquire(s.pool, bytes);
    if (!memory) return nullptr;
    if (pool_stats(s).active_bytes > s.active_budget) {
        ideck_memory_pool_release(s.pool, memory);
        return nullptr;
    }
    return memory;
}

extern "C" bool ideck_native_memory_release(void *pointer) {
    if (!pointer) return false;
    MemoryState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    return s.pool && ideck_memory_pool_release(s.pool, pointer);
}

extern "C" bool ideck_native_memory_snapshot(IDeckNativeMemoryStats *output) {
    if (!output) return false;
    MemoryState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    IDeckMemoryPoolStats stats = pool_stats(s);
    *output = {
        stats.active_allocations,
        stats.active_bytes,
        stats.cached_allocations,
        stats.cached_bytes,
        s.active_budget,
        s.configured_cache_budget,
        s.effective_cache_budget,
        s.pressure_events,
        s.reclaimed_bytes,
        s.pressure_level
    };
    return true;
}

extern "C" void ideck_native_memory_pressure(IDeckMemoryPressure pressure) {
    if (pressure != IDECK_MEMORY_PRESSURE_NORMAL &&
        pressure != IDECK_MEMORY_PRESSURE_WARNING &&
        pressure != IDECK_MEMORY_PRESSURE_CRITICAL) return;
    MemoryState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    if (pressure != IDECK_MEMORY_PRESSURE_NORMAL) ++s.pressure_events;
    s.pressure_level = static_cast<uint32_t>(pressure);
    size_t effective = pressure == IDECK_MEMORY_PRESSURE_CRITICAL
        ? 0
        : (pressure == IDECK_MEMORY_PRESSURE_WARNING ? s.configured_cache_budget / 4 : s.configured_cache_budget);
    s.effective_cache_budget = effective;
    reclaim_cache(s, effective);
}

extern "C" void ideck_native_memory_trim(void) {
    MemoryState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.pool) return;
    size_t before = pool_stats(s).cached_bytes;
    ideck_memory_pool_trim(s.pool);
    s.reclaimed_bytes += static_cast<uint64_t>(before);
}
