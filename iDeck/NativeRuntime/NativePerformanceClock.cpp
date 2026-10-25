#include "NativePerformance.h"

#include <chrono>
#include <cstdint>

extern "C" uint64_t ideck_performance_now_ns(void) {
    using Clock = std::chrono::steady_clock;
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now().time_since_epoch()).count());
}

extern "C" void ideck_performance_record_interval(uint64_t start_time_ns, uint64_t end_time_ns) {
    if (end_time_ns <= start_time_ns) return;
    ideck_performance_record_frame(end_time_ns - start_time_ns);
}
