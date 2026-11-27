// Phase 1 benchmark recorder (C++ core). Reached only through
// BenchmarkBridge.mm; Swift never includes this file.
#pragma once

#include <atomic>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "PipelineCounters.h"

namespace ideck::bench {

/// Platform probes supplied by the Objective-C++ bridge, so this file needs
/// no Apple frameworks beyond the C runtime.
struct Probes {
    uint64_t (*presentCount)() = nullptr;   // nullptr: no frame counter
    int (*thermalState)() = nullptr;        // 0 nominal ... 3 critical
    bool (*lowPowerMode)() = nullptr;
    uint64_t (*metalAllocatedBytes)() = nullptr;
};

struct Percentiles {
    bool available = false;
    double p50 = 0, p95 = 0, p99 = 0, max = 0;   // milliseconds
};

struct StageResult {
    uint64_t calls = 0, bytes = 0;
    double seconds = 0;
};

struct Report {
    std::string kind, label;
    double durationSeconds = 0;
    uint64_t frames = 0;
    double fpsAverage = 0;
    Percentiles frameTime;
    double frameTimeResolutionMs = 0;
    double cpuSeconds = 0, cpuPercentAverage = 0, cpuPercentPeak = 0;
    double memoryPeakMB = 0, memoryAverageMB = 0;
    double metalPeakMB = 0;
    bool metalAvailable = false;
    double thermalSeconds[4] = {0, 0, 0, 0};
    double lowPowerSeconds = 0;
    std::map<std::string, double> events;      // name -> seconds since start
    uint64_t installBytes = 0;
    StageResult stages[IDECK_STAGE_COUNT];
};

/// Records one session at a time: a game (frames, CPU, memory, thermal) or
/// an install (the same plus the pipeline stage counters). Sampling runs on
/// one thread: the frame counter every 4 ms, everything else once a second.
class Recorder {
public:
    static Recorder &shared();

    bool start(const std::string &kind, const std::string &label, const Probes &probes);
    void mark(const std::string &event);
    void setInstallBytes(uint64_t bytes);
    bool running() const { return running_.load(); }
    /// Stops sampling and returns the session's report.
    Report stop();

    static Percentiles percentiles(std::vector<uint32_t> intervalsMicros);

private:
    void loop();
    void sampleSecond(double elapsed);

    std::atomic<bool> running_{false};
    std::thread thread_;
    std::mutex mutex_;
    Probes probes_;
    Report report_;
    uint64_t startNs_ = 0;
    double startCpu_ = 0, lastCpu_ = 0, lastSampleSeconds_ = 0;
    double memorySum_ = 0;
    uint64_t memorySamples_ = 0;
    uint64_t lastPresent_ = 0, firstPresent_ = 0;
    uint64_t lastFrameNs_ = 0;
    std::vector<uint32_t> intervals_;
    IDeckStageTotals stageStart_[IDECK_STAGE_COUNT] {};
};

} // namespace ideck::bench
