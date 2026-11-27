// SystemCoordinator: Wine log, session outcome, memory sampling.
// Split from SystemCoordinator.swift (iDeck 3.0 architecture).

import Foundation
import UIKit
import Darwin

extension SystemCoordinator {
    static func rotateWineLogIfLarge(_ url: URL) {
        guard !ideck_wineprocess_running(), !ideck_wineserver_running(),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > wineLogRotateBytes else { return }
        let folder = url.deletingLastPathComponent()
        let previous = folder.appendingPathComponent("madeira-log.previous.txt.lzfse")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("madeira-log.previous.txt"))
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        try? FileManager.default.removeItem(at: previous)
        if (try? LogCompactor.writeCompressed(data: data, to: previous)) != nil {
            try? FileManager.default.removeItem(at: url)
            let kept = ((try? FileManager.default.attributesOfItem(atPath: previous.path)[.size] as? NSNumber)?.int64Value ?? 0)
            AppLog.record("[wine-log] madeira-log.txt reached \(size >> 20) MB: kept compacted as madeira-log.previous.txt.lzfse (\(kept >> 10) KB)")
        }
    }

    /// The Wine log of the last launch that failed, kept on its own: madeira-log.txt is
    /// rotated once it passes 8 MB, so after a few more sessions the failed one was gone
    /// (3.0: Dragon Age: Inquisition's crash, reported after four other sessions).
    static var failedWineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.failed.txt", isDirectory: false)
    }

    /// Copies what the failed session wrote to madeira-log.txt (its last 12 MB at most).
    static func keepFailedSessionLog(game: String, since offset: Int64?) {
        guard let offset, offset >= 0, let url = wineLogURL, let out = failedWineLogURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(offset) else { return }
        let cap: UInt64 = 12 << 20
        let start = max(UInt64(offset), size > cap ? size - cap : 0)
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return }
        var text = Data("[iDeck] Wine log of the failed launch of \(game), \(ISO8601DateFormatter().string(from: Date()))\n".utf8)
        text.append(data)
        if (try? text.write(to: out, options: .atomic)) != nil {
            AppLog.record("[wine-log] the failed launch's Wine log is kept as madeira-log.failed.txt (\(data.count >> 10) KB)")
        }
    }

    func captureWineLogStart() {
        guard let url = Self.wineLogURL else {
            wineLogStartOffset = nil
            return
        }
        Self.rotateWineLogIfLarge(url)
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        wineLogStartOffset = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func wineExitResult() -> (reason: String, ntstatus: UInt32?) {
        var nativeExitCode: Int32 = 0
        var nativeCrashStatus: UInt32 = 0
        let code = ideck_wineprocess_last_exit_code(&nativeExitCode) ? nativeExitCode : nil
        let nativeStatus = ideck_wineprocess_last_ntstatus(&nativeCrashStatus) ? nativeCrashStatus : nil
        var childStatus: UInt32 = 0
        if code == 0, nativeStatus == nil,
           let start = wineLogStartOffset, let path = Self.wineLogURL?.path {
            childStatus = path.withCString { ideck_wine_log_child_abort_since($0, start) }
        }
        let effectiveStatus = nativeStatus ?? (childStatus == 0 ? nil : childStatus)
        var reason = WineExitDiagnostics.message(exitCode: code, crashStatus: effectiveStatus)
        if childStatus != 0 {
            reason += " The Windows child process aborted. The Wine host exited with code 0."
        }
        return (reason, effectiveStatus)
    }

    /// Persist only public game identity, never store authentication or tokens.
    /// Last completed or attempted launch is shown in Bugs & logs and iRelay.
    /// How the last game session ended and the last stage it reached, kept for bug
    /// reports (a report after a crash runs in a new process).
    enum SessionOutcome {
        static let endKey = "diagnostics.session.end"
        static let stageKey = "diagnostics.session.stage"
        static let running = "running"

        static func began() {
            UserDefaults.standard.set(running, forKey: endKey)
            UserDefaults.standard.set("starting", forKey: stageKey)
        }

        static var isRunning: Bool { UserDefaults.standard.string(forKey: endKey) == running }

        /// A status while the session runs: an ending one is the session's end, any other
        /// is the stage it reached.
        static func status(_ status: String) {
            guard isRunning else { return }
            if status.hasPrefix("Execution Error") || status.hasPrefix("Cannot launch") || status.hasPrefix("Steam: ") {
                ended(status)
            } else if status == "Windows Ready" {
                ended("the game exited and Wine closed normally")
            } else {
                UserDefaults.standard.set(String(status.prefix(200)), forKey: stageKey)
            }
        }

        static func ended(_ reason: String) {
            guard isRunning else { return }
            UserDefaults.standard.set(String(reason.prefix(300)), forKey: endKey)
        }

        /// At iDeck's start: a session still marked running ended with the app itself.
        static func noteAppRestart() {
            ended("iDeck itself stopped while the game ran (a crash, iOS's memory limit, or the app was closed)")
        }
    }

    func recordGameContext(_ title: String, launcher: String) {
        let clean = title.replacingOccurrences(of: "[\\r\\n]", with: " ", options: .regularExpression)
        let safeTitle = String(clean.prefix(160))
        UserDefaults.standard.set(safeTitle, forKey: "diagnostics.lastGame")
        UserDefaults.standard.set(launcher, forKey: "diagnostics.lastLauncher")
        AppLog.record("[game-session] launcher=\(launcher) game=\(safeTitle)")
        SessionOutcome.began()
        LaunchReport.begin(title: safeTitle)
        sessionTempCutoff = Date()
        // The game gets the memory: covers and other caches iDeck rebuilds on demand
        // are dropped before it starts.
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: Notification.Name("iDeckReleaseCaches"), object: nil)
        startMemorySampling(launcher: launcher)
    }

    /// Ends the session's memory record: current, peak and available memory and
    /// why the session ended, logged and kept for Bugs & logs (SessionMemory).
    func finishMemorySampling(reason: String = "session ended", game: String? = nil) {
        memorySampler?.invalidate()
        memorySampler = nil
        let game = game ?? activeWindowsProfile?.id ?? activeSteamGameID.map { "steam:\($0)" }
        finishMemorySample?(reason, game)
        finishMemorySample = nil
    }

    private func startMemorySampling(launcher: String) {
        finishMemorySampling(reason: "replaced by a new session")
        let started = Date()
        let tracksInterval = IDResetSessionFootprint()
        var peakMiB = -1
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "diagnostics.sessionPeakMiB")
        defaults.set(false, forKey: "diagnostics.kernelPeak")
        // MemoryGuard reads these after iDeck restarts: which game ran and the least
        // memory iOS had left, sampled every 5 s so the last value is close to the end.
        defaults.set(activeWindowsProfile?.id ?? activeSteamGameID.map { "steam:\($0)" } ?? "", forKey: MemoryGuard.sessionGameKey)
        defaults.removeObject(forKey: MemoryGuard.lowestAvailableKey)
        var lowestAvailable = Int.max
        var tick = 0
        let log = { [weak self] (stage: String, reason: String?, gameID: String?) in
            let footprint = MainActor.assumeIsolated { ResourceGovernor.footprintMiB() }
            let kernelPeak = tracksInterval ? Int(IDSessionPeakMiB()) : -1
            let highest = max(footprint, kernelPeak)
            if highest > peakMiB {
                peakMiB = highest
                defaults.set(highest, forKey: "diagnostics.sessionPeakMiB")
            }
            if kernelPeak >= 0 { defaults.set(true, forKey: "diagnostics.kernelPeak") }
            AppLog.record("[memory] session \(stage) t=\(Int(Date().timeIntervalSince(started)))s footprint=\(footprint) MiB "
                          + "peak=\(peakMiB) MiB available=\(Int(os_proc_available_memory() >> 20)) MiB launcher=\(launcher) "
                          + "dock=\(self?.currentSteamLaunchUsesDock == true ? 1 : 0)"
                          + (reason.map { " reason=\($0)" } ?? ""))
            if let reason {
                let available = Int(os_proc_available_memory() >> 20)
                SessionMemory.record(SessionMemory.Entry(
                    game: gameID ?? launcher, launcher: launcher, started: started,
                    durationSeconds: Int(Date().timeIntervalSince(started)),
                    currentMiB: footprint, peakMiB: peakMiB, availableMiB: available,
                    reason: String(reason.prefix(300))))
                if let gameID { GameCompatibility.noteMemory(gameID, peakMiB: peakMiB, availableMiB: available) }
            }
        }
        log("start", nil, nil)
        finishMemorySample = { reason, game in
            defaults.removeObject(forKey: MemoryGuard.sessionGameKey)
            log("end", reason, game)
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            let available = Int(os_proc_available_memory() >> 20)
            if available < lowestAvailable {
                lowestAvailable = available
                defaults.set(available, forKey: MemoryGuard.lowestAvailableKey)
            }
            let footprint = MainActor.assumeIsolated { ResourceGovernor.footprintMiB() }
            if footprint > peakMiB { peakMiB = footprint; defaults.set(footprint, forKey: "diagnostics.sessionPeakMiB") }
            // The game id is known only once its profile is applied.
            if let id = MainActor.assumeIsolated({ self?.activeWindowsProfile?.id ?? self?.activeSteamGameID.map { "steam:\($0)" } }),
               defaults.string(forKey: MemoryGuard.sessionGameKey) != id {
                defaults.set(id, forKey: MemoryGuard.sessionGameKey)
            }
            tick += 1
            if tick % 6 == 0 { log("sample", nil, nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        memorySampler = timer
    }

    static func exportLastGoodPool() {
        let size = UserDefaults.standard.integer(forKey: lastGoodPoolKey)
        if size > 0 { setenv("IDECK_WINE_JIT_LAST_GOOD_MIB", String(size), 1) }
        else { unsetenv("IDECK_WINE_JIT_LAST_GOOD_MIB") }
    }

    static func exportWineJITPreference(_ sizeMiB: Int) {
        if supportedWineJITPoolMiB.contains(sizeMiB) {
            setenv("IDECK_WINE_JIT_MIB", String(sizeMiB), 1)
        } else {
            unsetenv("IDECK_WINE_JIT_MIB")
        }
    }

    // The native FEXRuntime reads IDECK_WINE_JIT_MIB only when preparing
    // the RX/RW pool; no mapped executable memory can be resized from UI.
    @discardableResult
    func updateWineJITPoolPreference(_ sizeMiB: Int) -> Bool {
        guard sizeMiB == 0 || Self.supportedWineJITPoolMiB.contains(sizeMiB) else {
            return false
        }
        guard !wineJITPreparationInFlight && !ideck_wine_jit_pool_ready() else {
            return false
        }
        Self.exportWineJITPreference(sizeMiB)
        UserDefaults.standard.removeObject(forKey: Self.lastGoodPoolKey)
        Self.exportLastGoodPool()
        return true
    }
}
