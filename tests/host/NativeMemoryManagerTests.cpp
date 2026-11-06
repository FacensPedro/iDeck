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


static void test_best_fit_cache_reuse() {
    auto *pool = ideck_memory_pool_create(8192);
    assert(pool);
    void *large = ideck_memory_pool_acquire(pool, 1024);
    void *exact = ideck_memory_pool_acquire(pool, 640);
    assert(large && exact);
    assert(ideck_memory_pool_release(pool, large));
    assert(ideck_memory_pool_release(pool, exact));

    // The larger cached block comes first, but the exact-size block must win.
    void *reused = ideck_memory_pool_acquire(pool, 640);
    assert(reused == exact);
    IDeckMemoryPoolStats stats{};
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.active_bytes == 640);
    assert(stats.cached_bytes == 1024);
    assert(ideck_memory_pool_release(pool, reused));
    ideck_memory_pool_destroy(pool);
}

static void test_active_budget_rejects_oversized_cache_block() {
    auto *pool = ideck_memory_pool_create(2048);
    assert(pool);
    void *oversized = ideck_memory_pool_acquire(pool, 800);
    void *active = ideck_memory_pool_acquire(pool, 600);
    assert(oversized && active);
    assert(ideck_memory_pool_release(pool, oversized));

    // 1024-byte active budget, 600 currently in use: an 800-byte cached
    // allocation cannot fulfill the new 400-byte request. malloc(400) can.
    void *fit = ideck_memory_pool_acquire_limited(pool, 400, 1024);
    assert(fit && fit != oversized);
    IDeckMemoryPoolStats stats{};
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.active_bytes == 1000);
    assert(stats.cached_bytes == 800);
    assert(!ideck_memory_pool_acquire_limited(pool, 25, 1024));
    assert(ideck_memory_pool_release(pool, fit));
    assert(ideck_memory_pool_release(pool, active));
    ideck_memory_pool_destroy(pool);
}

static void test_native_budget_uses_exact_size_fallback() {
    ideck_native_memory_trim();
    assert(ideck_native_memory_configure(2048, 2048));
    void *cached = ideck_native_memory_acquire(800);
    void *live = ideck_native_memory_acquire(600);
    assert(cached && live);
    assert(ideck_native_memory_release(cached));
    assert(ideck_native_memory_configure(1024, 1024));
    void *fits = ideck_native_memory_acquire(400);
    assert(fits && fits != cached);
    IDeckNativeMemoryStats snapshot{};
    assert(ideck_native_memory_snapshot(&snapshot));
    assert(snapshot.active_bytes == 1000);
    assert(snapshot.cached_bytes == 800);
    assert(ideck_native_memory_release(fits));
    assert(ideck_native_memory_release(live));
    ideck_native_memory_trim();
    assert(ideck_native_memory_configure(1024, 256));
}

static void test_cache_reclamation_is_atomic_and_exact() {
    auto *pool = ideck_memory_pool_create(4096);
    assert(pool);
    void *one = ideck_memory_pool_acquire(pool, 256);
    void *two = ideck_memory_pool_acquire(pool, 512);
    void *three = ideck_memory_pool_acquire(pool, 1024);
    assert(one && two && three);
    assert(ideck_memory_pool_release(pool, one));
    assert(ideck_memory_pool_release(pool, two));
    assert(ideck_memory_pool_release(pool, three));

    // The pool trims only released allocations, and never double-counts them.
    assert(ideck_memory_pool_set_cache_limit_reclaimed(pool, 1024) == 1024);
    IDeckMemoryPoolStats stats{};
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_bytes == 768);
    assert(ideck_memory_pool_set_cache_limit_reclaimed(pool, 1024) == 0);
    assert(ideck_memory_pool_trim_reclaimed(pool) == 768);
    assert(ideck_memory_pool_trim_reclaimed(pool) == 0);
    assert(ideck_memory_pool_set_cache_limit_reclaimed(nullptr, 0) == 0);
    assert(ideck_memory_pool_trim_reclaimed(nullptr) == 0);
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_bytes == 0);
    ideck_memory_pool_destroy(pool);
}

static void test_reclaim_pressure_does_not_release_active_buffers() {
    assert(ideck_native_memory_configure(4096, 4096));
    auto *live = ideck_native_memory_acquire(256);
    auto *released = ideck_native_memory_acquire(512);
    assert(live && released);
    assert(ideck_native_memory_release(released));
    IDeckNativeMemoryStats before{}, after{};
    assert(ideck_native_memory_snapshot(&before));
    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_CRITICAL);
    assert(ideck_native_memory_snapshot(&after));
    assert(after.cached_bytes == 0);
    assert(after.active_bytes == 256);
    assert(after.reclaimed_cached_bytes == before.reclaimed_cached_bytes + before.cached_bytes);
    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_CRITICAL);
    IDeckNativeMemoryStats repeated{};
    assert(ideck_native_memory_snapshot(&repeated));
    assert(repeated.reclaimed_cached_bytes == after.reclaimed_cached_bytes);
    assert(ideck_native_memory_release(live));
    ideck_native_memory_pressure(IDECK_MEMORY_PRESSURE_NORMAL);
    ideck_native_memory_trim();
    assert(ideck_native_memory_configure(1024, 256));
}

int main() {
    test_budget_limits();
    test_pressure();
    test_concurrent_allocations();
    test_pool_reduction();
    test_best_fit_cache_reuse();
    test_active_budget_rejects_oversized_cache_block();
    test_native_budget_uses_exact_size_fallback();
    test_cache_reclamation_is_atomic_and_exact();
    test_reclaim_pressure_does_not_release_active_buffers();
    return 0;
}
