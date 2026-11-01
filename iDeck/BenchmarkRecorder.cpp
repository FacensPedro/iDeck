#include "BenchmarkRecorder.hpp"

#include <algorithm>
#include <chrono>
#include <mach/mach.h>
#include <sys/resource.h>

namespace ideck::bench {

namespace {
constexpr uint64_t kFramePollNs = 4'000'000;       // 4 ms
constexpr size_t kMaxIntervals = 4'000'000;        // ~18 h at 60 fps

double cpuSecondsNow() {
    rusage usage {};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

/// The footprint iOS counts against the app's memory limit.
double footprintMB() {
    task_vm_info_data_t info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
        return 0;
    return static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
}
} // namespace

Recorder &Recorder::shared() {
    static Recorder recorder;
    return recorder;
}

bool Recorder::start(const std::string &kind, const std::string &label, const Probes &probes) {
    if (running_.exchange(true)) return false;
    if (thread_.joinable()) thread_.join();
    std::lock_guard<std::mutex> lock(mutex_);
    probes_ = probes;
    report_ = Report {};
    report_.kind = kind;
    report_.label = label;
    report_.frameTimeResolutionMs = kFramePollNs / 1e6;
    startNs_ = ideck_stage_now();
    startCpu_ = lastCpu_ = cpuSecondsNow();
    lastSampleSeconds_ = 0;
    memorySum_ = 0;
    memorySamples_ = 0;
    intervals_.clear();
    intervals_.reserve(64 * 1024);
    firstPresent_ = lastPresent_ = probes_.presentCount ? probes_.presentCount() : 0;
    lastFrameNs_ = 0;
    for (int stage = 0; stage < IDECK_STAGE_COUNT; ++stage)
        stageStart_[stage] = ideck_stage_totals(static_cast<IDeckStage>(stage));
    report_.events["start"] = 0;
    thread_ = std::thread([this] { loop(); });
    return true;
}

void Recorder::mark(const std::string &event) {
    if (!running_.load()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    // First occurrence only: "first_frame" means the first one.
    report_.events.emplace(event, (ideck_stage_now() - startNs_) / 1e9);
}

void Recorder::setInstallBytes(uint64_t bytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    report_.installBytes = bytes;
}

void Recorder::loop() {
    uint64_t nextSecond = startNs_ + 1'000'000'000ULL;
    while (running_.load(std::memory_order_relaxed)) {
        const uint64_t now = ideck_stage_now();
        if (probes_.presentCount) {
            const uint64_t count = probes_.presentCount();
            if (count > lastPresent_) {
                std::lock_guard<std::mutex> lock(mutex_);
                const uint64_t frames = count - lastPresent_;
                if (lastFrameNs_ != 0 && intervals_.size() < kMaxIntervals) {
                    // Several presents within one poll share its interval.
                    const uint64_t each = (now - lastFrameNs_) / frames;
                    for (uint64_t i = 0; i < frames; ++i)
                        intervals_.push_back(static_cast<uint32_t>(std::min<uint64_t>(each / 1000, UINT32_MAX)));
                }
                if (lastFrameNs_ == 0) report_.events.emplace("first_frame", (now - startNs_) / 1e9);
                lastFrameNs_ = now;
                lastPresent_ = count;
            }
        }
        if (now >= nextSecond) {
            sampleSecond((now - startNs_) / 1e9);
            nextSecond += 1'000'000'000ULL;
        }
        std::this_thread::sleep_for(std::chrono::nanoseconds(probes_.presentCount ? kFramePollNs : 250'000'000ULL));
    }
}

void Recorder::sampleSecond(double elapsed) {
    const double cpu = cpuSecondsNow();
    const double memory = footprintMB();
    std::lock_guard<std::mutex> lock(mutex_);
    const double span = elapsed - lastSampleSeconds_;
    if (span > 0) {
        report_.cpuPercentPeak = std::max(report_.cpuPercentPeak, (cpu - lastCpu_) / span * 100.0);
        if (probes_.thermalState) {
            const int state = std::clamp(probes_.thermalState(), 0, 3);
            report_.thermalSeconds[state] += span;
        }
        if (probes_.lowPowerMode && probes_.lowPowerMode()) report_.lowPowerSeconds += span;
    }
    lastCpu_ = cpu;
    lastSampleSeconds_ = elapsed;
    report_.memoryPeakMB = std::max(report_.memoryPeakMB, memory);
    memorySum_ += memory;
    ++memorySamples_;
    if (probes_.metalAllocatedBytes) {
        report_.metalAvailable = true;
        report_.metalPeakMB = std::max(report_.metalPeakMB, probes_.metalAllocatedBytes() / (1024.0 * 1024.0));
    }
}

Report Recorder::stop() {
    if (!running_.exchange(false)) return Report {};
    if (thread_.joinable()) thread_.join();
    const double elapsed = (ideck_stage_now() - startNs_) / 1e9;
    sampleSecond(elapsed);
    std::lock_guard<std::mutex> lock(mutex_);
    Report result = report_;
    result.durationSeconds = elapsed;
    result.cpuSeconds = cpuSecondsNow() - startCpu_;
    result.cpuPercentAverage = elapsed > 0 ? result.cpuSeconds / elapsed * 100.0 : 0;
    result.memoryAverageMB = memorySamples_ ? memorySum_ / memorySamples_ : 0;
    result.frames = lastPresent_ - firstPresent_;
    const auto first = result.events.find("first_frame");
    const double renderSpan = first != result.events.end() ? elapsed - first->second : 0;
    result.fpsAverage = renderSpan > 0 ? (result.frames > 0 ? (result.frames - 1) / renderSpan : 0) : 0;
    result.frameTime = percentiles(intervals_);
    for (int stage = 0; stage < IDECK_STAGE_COUNT; ++stage) {
        const IDeckStageTotals now = ideck_stage_totals(static_cast<IDeckStage>(stage));
        result.stages[stage].calls = now.calls - stageStart_[stage].calls;
        result.stages[stage].bytes = now.bytes - stageStart_[stage].bytes;
        result.stages[stage].seconds = (now.nanoseconds - stageStart_[stage].nanoseconds) / 1e9;
    }
    return result;
}

Percentiles Recorder::percentiles(std::vector<uint32_t> values) {
    Percentiles out;
    if (values.size() < 30) return out;   // too few frames to mean anything
    std::sort(values.begin(), values.end());
    auto at = [&](double q) {
        const size_t index = std::min(values.size() - 1, static_cast<size_t>(q * (values.size() - 1) + 0.5));
        return values[index] / 1000.0;
    };
    out.available = true;
    out.p50 = at(0.50);
    out.p95 = at(0.95);
    out.p99 = at(0.99);
    out.max = values.back() / 1000.0;
    return out;
}

} // namespace ideck::bench
