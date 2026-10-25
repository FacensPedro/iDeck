#include "../../iDeck/NativeRuntime/NativeMemoryManager.h"
#include "../../iDeck/NativeRuntime/NativePerformance.h"

#include <cassert>
#include <cstdint>
#include <thread>
#include <vector>

static void test_budget_limits() {
    assert(!ideck_native_memory_configure(0, 0));
    assert(!ideck_native_memory_configure(100, 101));
    assert(!ideck_native_memory_configure(513ull * 1024ull * 1024ull, 0));
    assert(ideck_native_memory_configure(1024, 256));

    void *first = ideck_native_memory_acquire(128);
    void *second = ideck_native_memory_acquire(64);
    assert(first && second);
    assert(!ideck_native_memory_acquire(1024));
    assert(!ideck_native_memory_configure(100, 10));

    IDeckNativeMemoryStats snapshot{};
    assert(ideck_native_memory_snapshot(&snapshot));
    assert(snapshot.active_allocations == 2);
    assert(snapshot.active_bytes == 192);
    assert(snapshot.active_budget_bytes == 1024);

    assert(ideck_native_memory_release(first));
    assert(ideck_native_memory_release(second));
    assert(!ideck_native_memory_release(first));
    assert(ideck_native_memory_snapshot(&snapshot));
    assert(snapshot.cached_bytes == 192);
}

static void test_pressure() {
    IDeckNativeMemoryStats before{};
    assert(ideck_native_memory_snapshot(&before));

    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_WARNING);
    IDeckNativeMemoryStats warning{};
    assert(ideck_native_memory_snapshot(&warning));
    assert(warning.pressure_level == IDECK_MEMORY_PRESSURE_WARNING);
    assert(warning.effective_cache_budget_bytes == 64);
    assert(warning.cached_bytes <= 64);
    assert(warning.pressure_events == before.pressure_events + 1);
    assert(warning.reclaimed_cached_bytes >= before.reclaimed_cached_bytes + 128);

    void *small = ideck_native_memory_acquire(32);
    assert(small);
    assert(ideck_native_memory_release(small));
    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_CRITICAL);
    IDeckNativeMemoryStats critical{};
    assert(ideck_native_memory_snapshot(&critical));
    assert(critical.effective_cache_budget_bytes == 0);
    assert(critical.cached_bytes == 0);

    void *active = ideck_native_memory_acquire(128);
    assert(active);
    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_CRITICAL);
    assert(ideck_native_memory_snapshot(&critical));
    assert(critical.active_allocations == 1);
    assert(critical.active_bytes == 128);
    assert(ideck_native_memory_release(active));
    assert(ideck_native_memory_snapshot(&critical));
    assert(critical.cached_bytes == 0);

    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_NORMAL);
    IDeckNativeMemoryStats restored{};
    assert(ideck_native_memory_snapshot(&restored));
    assert(restored.effective_cache_budget_bytes == 256);
    assert(restored.pressure_level == IDECK_MEMORY_PRESSURE_NORMAL);
    assert(ideck_native_memory_configure(1024, 256));
}

static void test_concurrent_allocations() {
    assert(ideck_native_memory_configure(65536, 4096));
    std::vector<std::thread> threads;
    for (int index = 0; index < 4; ++index) {
        threads.emplace_back([] {
            for (int iteration = 0; iteration < 400; ++iteration) {
                void *block = ideck_native_memory_acquire(64);
                assert(block);
                assert(ideck_native_memory_release(block));
            }
        });
    }
    for (auto &thread : threads) thread.join();

    IDeckNativeMemoryStats snapshot{};
    assert(ideck_native_memory_snapshot(&snapshot));
    assert(snapshot.active_allocations == 0);
    assert(snapshot.active_bytes == 0);
    assert(snapshot.cached_bytes <= 4096);

    ideck_native_memory_trim();
    assert(ideck_native_memory_snapshot(&snapshot));
    assert(snapshot.cached_bytes == 0);
    assert(!ideck_native_memory_snapshot(nullptr));
    assert(!ideck_native_memory_release(nullptr));
    assert(!ideck_native_memory_acquire(0));
}

static void test_pool_reduction() {
    auto *pool = ideck_memory_pool_create(4096);
    assert(pool);
    void *block = ideck_memory_pool_acquire(pool, 1024);
    assert(block);
    assert(ideck_memory_pool_release(pool, block));
    IDeckMemoryPoolStats stats{};
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_bytes == 1024);
    assert(ideck_memory_pool_set_cache_limit(pool, 0));
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_bytes == 0);
    assert(!ideck_memory_pool_set_cache_limit(nullptr, 0));
    ideck_memory_pool_destroy(pool);
}

int main() {
    test_budget_limits();
    test_pressure();
    test_concurrent_allocations();
    test_pool_reduction();
    return 0;
}
