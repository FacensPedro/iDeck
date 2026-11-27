// ResourceGovernor: memory readings, pressure and releasing caches.
// Split from ResourceGovernor.swift (iDeck 3.0 architecture).

import AVFoundation
import Foundation

extension ResourceGovernor {
    static func footprintMiB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }

    static func availableMiB() -> Int { Int(os_proc_available_memory() >> 20) }

    /// After a game session: what iDeck rebuilds on demand is dropped, so the
    /// next session (after the restart Madeira requires) and the library start
    /// from a smaller footprint.
    func releaseAfterSession() {
        let before = Self.footprintMiB()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: Self.releaseCachesNotification, object: nil)
        AppLog.record("[memory] session ended: footprint \(before) MiB -> \(Self.footprintMiB()) MiB, \(Self.availableMiB()) MiB left")
    }

    /// After the last download of a queue ended: the network cache goes, and the
    /// allocator hands back the pages the download's buffers used. Freed memory
    /// otherwise stays with the app as dirty pages and keeps counting toward the limit
    /// a game needs.
    func releaseAfterDownload() {
        let before = Self.footprintMiB()
        URLCache.shared.removeAllCachedResponses()
        let returned = malloc_zone_pressure_relief(nil, 0)
        AppLog.record("[memory] downloads ended: footprint \(before) MiB -> \(Self.footprintMiB()) MiB, "
                      + "\(returned >> 20) MiB handed back by the allocator, \(Self.availableMiB()) MiB left")
    }

    func memoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let level = event.contains(.critical) ? "critical" : "warning"
        let before = Self.footprintMiB()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: Self.releaseCachesNotification, object: nil)
        // A critical iOS memory-pressure event is system-wide; it is not
        // automatically evidence of jetsam or a process exceeding its limit.
        // Capture foreground state and the active Steam installation count
        // so a later restart report can distinguish game execution and USB
        // transfer activity from an actual process termination record.
        let steamInstalls = SteamOwnedGamesModel.shared.installingApps.count
        AppLog.record("[memory] pressure \(level): footprint \(before) MiB -> \(Self.footprintMiB()) MiB after releasing caches, " +
                      "\(Self.availableMiB()) MiB left before the system limit, game running: \(Self.gameRunning), " +
                      "app active: \(Self.appActive), Steam installs: \(steamInstalls)")
        BenchmarkSession.mark("memory_pressure_" + level)
    }
}
