import Foundation
import UIKit

/// Phase 1 benchmarks: records game and install sessions with the native
/// recorder (BenchmarkRecorder.cpp via IDBenchmarkRecorder) and writes one
/// JSON report per session to Documents/iDeck/Benchmarks, visible in Files.
/// Off by default (Settings › Bugs & logs › Record benchmarks).
/// `scripts/benchmark_report.py` aggregates and compares the reports.
enum BenchmarkSession {
    static let enabledKey = "benchmarks.enabled"
    static let schema = 1

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck/Benchmarks", isDirectory: true)
    }

    private static var context: [String: Any] = [:]
    /// The kind of the session being recorded, if any.
    private(set) static var currentKind: String?

    /// Starts recording a game ("game") or an install ("install").
    /// `scenario` names what is measured (the game's title, an install of
    /// it); `settings` are the runtime choices that shape the result.
    static func gameSettings(_ profile: WindowsGameProfile?) -> [String: Any] {
        guard let profile else { return [:] }
        return ["resolution": profile.resolution, "fpsLimit": profile.fpsLimit, "graphicsAPI": profile.graphicsAPI,
                "metalFX": profile.metalFXEnabled, "codeChecks": profile.codeChecks, "avx": profile.avxEnabled,
                "surfaceScaling": profile.surfaceScaling, "vulkan": profile.vulkanMode, "openGL": profile.openGLBackend]
    }

    static func begin(kind: String, scenario: String, settings: [String: Any] = [:]) {
        // One session at a time: a running one (an install during a game,
        // a launch retried after a prompt) keeps recording.
        guard isEnabled, currentKind == nil,
              IDBenchmarkRecorder.start(withKind: kind, label: scenario) else { return }
        currentKind = kind
        context = ["startedAt": ISO8601DateFormatter().string(from: Date()), "settings": settings]
    }

    static func mark(_ event: String, kind: String = "game") {
        guard currentKind == kind, IDBenchmarkRecorder.isRunning() else { return }
        IDBenchmarkRecorder.mark(event)
    }

    /// Ends the session and writes its report. `outcome` says how it ended
    /// ("completed", "closed", "failed: …"); `installBytes` is the size
    /// installed, for install sessions.
    static func finish(kind: String, outcome: String, installBytes: UInt64 = 0) {
        guard currentKind == kind, IDBenchmarkRecorder.isRunning() else { return }
        currentKind = nil
        if installBytes > 0 { IDBenchmarkRecorder.setInstallBytes(installBytes) }
        guard let metrics = IDBenchmarkRecorder.stop() else { return }
        var report = context
        report["schema"] = schema
        report["outcome"] = outcome
        report["environment"] = environment()
        report["metrics"] = metrics
        report["derived"] = derived(metrics)
        report["unavailable"] = unavailable(metrics)
        context = [:]
        write(report, kind: metrics["kind"] as? String ?? "session")
    }

    // MARK: - Report parts

    static func environment() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let runtime = MadeiraBundleIdentity.profile
        let jit = ideck_jit_snapshot()
        return [
            "device": machine,
            "deviceFamily": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "systemVersion": UIDevice.current.systemVersion,
            "physicalMemoryMB": ProcessInfo.processInfo.physicalMemory / 1_048_576,
            "processorCount": ProcessInfo.processInfo.activeProcessorCount,
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "?",
            "appBuild": info["CFBundleVersion"] as? String ?? "?",
            "sourceCommit": runtime["sourceCommit"] as? String ?? "unknown",
            "runtimeKind": runtime["runtimeKind"] as? String ?? "unknown",
            "graphicsBackend": runtime["graphicsBackend"] as? String ?? "unknown",
            "wineJITPoolMiB": jit.wine_pool_mib,
            "detailedDiagnostics": UserDefaults.standard.bool(forKey: "diagnostics.detailed"),
            "unlimitedDownloadSpeed": DownloadSpeed.isUnlimited,
        ]
    }

    /// Figures computed from the raw measurements, per the plan's targets.
    static func derived(_ metrics: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        let events = metrics["events"] as? [String: Double] ?? [:]
        if let wine = events["wine_started"] { out["wineStartSeconds"] = wine }
        if let frame = events["first_frame"] { out["firstFrameSeconds"] = frame }
        let bytes = (metrics["installBytes"] as? NSNumber)?.doubleValue ?? 0
        let seconds = (metrics["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
        let cpu = (metrics["cpuSeconds"] as? NSNumber)?.doubleValue ?? 0
        if bytes > 0, seconds > 0 {
            let gib = bytes / 1_073_741_824
            out["installMegabytesPerSecond"] = bytes / 1_048_576 / seconds
            out["cpuSecondsPerGiB"] = cpu / gib
        }
        return out
    }

    /// Metrics the plan asks for that this device or build cannot measure.
    /// Listed rather than guessed.
    static func unavailable(_ metrics: [String: Any]) -> [String] {
        var missing = [
            "gpuTimePerFrame (no per-frame GPU timestamps from DXMT/madeira-d3d12)",
            "energy (iOS exposes no per-app power reading)",
            "temperatureCelsius (iOS reports only the thermal state)",
        ]
        if metrics["frameTimeMs"] is NSNull { missing.append("frameTimePercentiles (fewer than 30 frames, or no frame counter)") }
        if metrics["metalPeakMB"] is NSNull { missing.append("metalMemory (no Metal device)") }
        if (metrics["kind"] as? String) == "game",
           (metrics["events"] as? [String: Double])?["first_frame"] == nil {
            missing.append("firstFrame (the game presented no frame)")
        }
        return missing
    }

    private static func write(_ report: [String: Any], kind: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = folder.appendingPathComponent("\(kind)-\(stamp).json")
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            AppLog.record("[benchmark] saved \(file.lastPathComponent)")
        } catch {
            AppLog.record("[benchmark] could not save report: \(error.localizedDescription)")
        }
    }

    static func reports() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
