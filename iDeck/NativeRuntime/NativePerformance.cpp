// Native frame clock and lock-free performance counters.
#include "NativePerformance.h"

#include <atomic>
#include <chrono>
#include <cstdint>

namespace {
std::atomic<uint64_t> frame_count{0};
std::atomic<uint64_t> total_frame_ns{0};
std::atomic<uint64_t> peak_frame_ns{0};
std::atomic<uint64_t> swapchain_count{0};
}

extern "C" uint64_t ideck_performance_now_ns(void) {
    using Clock = std::chrono::steady_clock;
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now().time_since_epoch()).count());
}

extern "C" void ideck_performance_reset(void) {
    frame_count.store(0, std::memory_order_relaxed);
    total_frame_ns.store(0, std::memory_order_relaxed);
    peak_frame_ns.store(0, std::memory_order_relaxed);
    swapchain_count.store(0, std::memory_order_relaxed);
}

extern "C" void ideck_performance_record_frame(uint64_t duration_ns) {
    if (!duration_ns) return;
    frame_count.fetch_add(1, std::memory_order_relaxed);
    total_frame_ns.fetch_add(duration_ns, std::memory_order_relaxed);
    uint64_t expected = peak_frame_ns.load(std::memory_order_relaxed);
    while (duration_ns > expected &&
           !peak_frame_ns.compare_exchange_weak(expected, duration_ns, std::memory_order_relaxed)) {
    }
}

extern "C" void ideck_performance_record_interval(uint64_t start_time_ns, uint64_t end_time_ns) {
    if (end_time_ns <= start_time_ns) return;
    ideck_performance_record_frame(end_time_ns - start_time_ns);
}

extern "C" void ideck_performance_record_swapchain(void) {
    swapchain_count.fetch_add(1, std::memory_order_relaxed);
}

extern "C" IDeckPerformanceSnapshot ideck_performance_snapshot(void) {
    return {
        frame_count.load(std::memory_order_relaxed),
        total_frame_ns.load(std::memory_order_relaxed),
        peak_frame_ns.load(std::memory_order_relaxed),
        swapchain_count.load(std::memory_order_relaxed)
    };
}
