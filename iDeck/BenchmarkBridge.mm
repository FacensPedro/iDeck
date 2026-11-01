#import "BenchmarkBridge.h"
#import <Metal/Metal.h>
#include <dlfcn.h>
#include "BenchmarkRecorder.hpp"

using ideck::bench::Recorder;

namespace {
uint64_t (*madeiraPresentCount)() = nullptr;

uint64_t presentCount() { return madeiraPresentCount ? madeiraPresentCount() : 0; }

int thermalState() {
    switch (NSProcessInfo.processInfo.thermalState) {
    case NSProcessInfoThermalStateNominal: return 0;
    case NSProcessInfoThermalStateFair: return 1;
    case NSProcessInfoThermalStateSerious: return 2;
    default: return 3;
    }
}

bool lowPowerMode() { return NSProcessInfo.processInfo.isLowPowerModeEnabled; }

id<MTLDevice> metalDevice() {
    static id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device;
}

uint64_t metalAllocated() { return metalDevice().currentAllocatedSize; }

NSDictionary *stage(const ideck::bench::StageResult &result) {
    return @{@"calls": @(result.calls), @"bytes": @(result.bytes), @"seconds": @(result.seconds),
             @"megabytesPerSecond": result.seconds > 0 ? @(result.bytes / 1048576.0 / result.seconds) : [NSNull null]};
}
} // namespace

@implementation IDBenchmarkRecorder

+ (BOOL)startWithKind:(NSString *)kind label:(NSString *)label {
    ideck::bench::Probes probes;
    madeiraPresentCount = reinterpret_cast<uint64_t (*)()>(dlsym(RTLD_DEFAULT, "madeira_get_present_count"));
    probes.presentCount = madeiraPresentCount ? presentCount : nullptr;
    probes.thermalState = thermalState;
    probes.lowPowerMode = lowPowerMode;
    probes.metalAllocatedBytes = metalDevice() ? metalAllocated : nullptr;
    return Recorder::shared().start(kind.UTF8String, label.UTF8String, probes);
}

+ (void)mark:(NSString *)event { Recorder::shared().mark(event.UTF8String); }

+ (void)setInstallBytes:(uint64_t)bytes { Recorder::shared().setInstallBytes(bytes); }

+ (BOOL)isRunning { return Recorder::shared().running(); }

+ (nullable NSDictionary<NSString *, id> *)stop {
    if (!Recorder::shared().running()) return nil;
    const ideck::bench::Report r = Recorder::shared().stop();
    NSMutableDictionary *events = [NSMutableDictionary dictionary];
    for (const auto &[name, seconds] : r.events) events[@(name.c_str())] = @(seconds);
    NSNull *none = [NSNull null];
    return @{
        @"kind": @(r.kind.c_str()),
        @"label": @(r.label.c_str()),
        @"durationSeconds": @(r.durationSeconds),
        @"frames": @(r.frames),
        @"fpsAverage": r.frames > 0 ? @(r.fpsAverage) : none,
        @"frameTimeMs": r.frameTime.available
            ? @{@"p50": @(r.frameTime.p50), @"p95": @(r.frameTime.p95), @"p99": @(r.frameTime.p99), @"max": @(r.frameTime.max)}
            : none,
        @"frameTimeResolutionMs": @(r.frameTimeResolutionMs),
        @"cpuSeconds": @(r.cpuSeconds),
        @"cpuPercentAverage": @(r.cpuPercentAverage),
        @"cpuPercentPeak": @(r.cpuPercentPeak),
        @"memoryPeakMB": @(r.memoryPeakMB),
        @"memoryAverageMB": @(r.memoryAverageMB),
        @"metalPeakMB": r.metalAvailable ? @(r.metalPeakMB) : none,
        @"thermalSeconds": @{@"nominal": @(r.thermalSeconds[0]), @"fair": @(r.thermalSeconds[1]),
                             @"serious": @(r.thermalSeconds[2]), @"critical": @(r.thermalSeconds[3])},
        @"lowPowerSeconds": @(r.lowPowerSeconds),
        @"events": events,
        @"installBytes": @(r.installBytes),
        @"stages": @{@"decrypt": stage(r.stages[IDECK_STAGE_DECRYPT]),
                     @"decompress": stage(r.stages[IDECK_STAGE_DECOMPRESS]),
                     @"write": stage(r.stages[IDECK_STAGE_WRITE])},
    };
}

@end
