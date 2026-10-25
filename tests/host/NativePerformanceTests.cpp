#include "../../iDeck/NativeRuntime/NativePerformance.h"

#include <atomic>
#include <cassert>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>

struct BlockedTask {
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false;
    bool released = false;
    std::atomic<int> completed{0};
};

static void wait_for_release(void *context) {
    auto &state = *static_cast<BlockedTask *>(context);
    std::unique_lock<std::mutex> lock(state.mutex);
    state.entered = true;
    state.changed.notify_all();
    state.changed.wait(lock, [&state] { return state.released; });
    ++state.completed;
}

static void count_task(void *context) {
    ++(*static_cast<std::atomic<int> *>(context));
}

static void test_scheduler() {
    assert(!ideck_scheduler_create(0, 4));
    assert(!ideck_scheduler_create(17, 4));
    assert(!ideck_scheduler_create(1, 0));
    auto *scheduler = ideck_scheduler_create(1, 1);
    assert(scheduler);
    BlockedTask blocked;
    std::atomic<int> completed{0};
    assert(ideck_scheduler_submit(scheduler, wait_for_release, &blocked));
    {
        std::unique_lock<std::mutex> lock(blocked.mutex);
        blocked.changed.wait(lock, [&blocked] { return blocked.entered; });
    }
    assert(ideck_scheduler_submit(scheduler, count_task, &completed));
    assert(!ideck_scheduler_submit(scheduler, count_task, &completed));
    assert(ideck_scheduler_pending(scheduler) == 2);
    {
        std::lock_guard<std::mutex> lock(blocked.mutex);
        blocked.released = true;
    }
    blocked.changed.notify_all();
    ideck_scheduler_wait_idle(scheduler);
    assert(completed.load() == 1);
    assert(blocked.completed.load() == 1);
    assert(ideck_scheduler_pending(scheduler) == 0);
    ideck_scheduler_destroy(scheduler);
    ideck_scheduler_wait_idle(nullptr);
    assert(!ideck_scheduler_submit(nullptr, count_task, &completed));
}

static void test_memory_pool() {
    assert(!ideck_memory_pool_acquire(nullptr, 64));
    auto *pool = ideck_memory_pool_create(1024);
    assert(pool);
    assert(!ideck_memory_pool_acquire(pool, 0));
    void *first = ideck_memory_pool_acquire(pool, 128);
    assert(first);
    IDeckMemoryPoolStats stats{};
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.active_allocations == 1 && stats.active_bytes == 128);
    assert(ideck_memory_pool_release(pool, first));
    assert(!ideck_memory_pool_release(pool, first));
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_allocations == 1 && stats.cached_bytes == 128);
    void *second = ideck_memory_pool_acquire(pool, 100);
    assert(second == first);
    assert(ideck_memory_pool_release(pool, second));
    void *large = ideck_memory_pool_acquire(pool, 2048);
    assert(large);
    assert(ideck_memory_pool_release(pool, large));
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_bytes == 128);
    void *external = std::malloc(8);
    assert(!ideck_memory_pool_release(pool, external));
    std::free(external);
    ideck_memory_pool_trim(pool);
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.cached_bytes == 0 && stats.cached_allocations == 0);
    ideck_memory_pool_destroy(pool);
}

static void test_parallel_pool() {
    auto *pool = ideck_memory_pool_create(4096);
    assert(pool);
    std::vector<std::thread> threads;
    for (int index = 0; index < 4; ++index) {
        threads.emplace_back([pool] {
            for (int iteration = 0; iteration < 200; ++iteration) {
                void *pointer = ideck_memory_pool_acquire(pool, 64);
                assert(pointer);
                assert(ideck_memory_pool_release(pool, pointer));
            }
        });
    }
    for (auto &thread : threads) thread.join();
    IDeckMemoryPoolStats stats{};
    assert(ideck_memory_pool_stats(pool, &stats));
    assert(stats.active_bytes == 0);
    assert(stats.cached_bytes <= 4096);
    ideck_memory_pool_destroy(pool);
}

static void test_telemetry() {
    ideck_performance_reset();
    auto initial = ideck_performance_snapshot();
    assert(initial.frame_count == 0);
    ideck_performance_record_frame(16000000);
    ideck_performance_record_frame(20000000);
    ideck_performance_record_frame(0);
    ideck_performance_record_swapchain();
    auto result = ideck_performance_snapshot();
    assert(result.frame_count == 2);
    assert(result.total_frame_time_ns == 36000000);
    assert(result.peak_frame_time_ns == 20000000);
    assert(result.swapchain_creations == 1);
    uint64_t start = ideck_performance_now_ns();
    uint64_t end = ideck_performance_now_ns();
    assert(end >= start);
    ideck_performance_record_interval(50, 60);
    result = ideck_performance_snapshot();
    assert(result.frame_count == 3);
    assert(result.total_frame_time_ns == 36000010);
}

int main() {
    test_scheduler();
    test_memory_pool();
    test_parallel_pool();
    test_telemetry();
    return 0;
}
