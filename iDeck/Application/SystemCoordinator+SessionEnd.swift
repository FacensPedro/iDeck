// SystemCoordinator: closing a session, cleanup and recovery.
// Split from SystemCoordinator.swift (iDeck 3.0 architecture).

import Foundation
import UIKit
import Darwin

extension SystemCoordinator {
    /// When a Windows session has ended (an installer finished or was stopped, a game
    /// closed), frees its JIT pool as soon as the Wine worker and the wineserver have
    /// stopped. A launch that failed before Wine started keeps the pool for the retry.
    func releaseJITPoolAfterSession(remaining: Int = 40) {
        guard WindowsEnvironment.sessionsThisRun > 0 else { return }
        if !ideck_wineprocess_running() {
            if ideck_wineprocess_thread_finished() && ideck_wineserver_running() {
                _ = ideck_wineserver_stop_if_idle()
            }
            if ideck_runtime_complete_session() {
                DispatchQueue.global(qos: .utility).async {
                    MadeiraWinePool.release()
                    DispatchQueue.main.async { self.refreshJITStatus() }
                }
                return
            }
        }
        guard remaining > 0 else {
            AppLog.record("[jit-pool] kept: the Windows session did not finish closing")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.releaseJITPoolAfterSession(remaining: remaining - 1)
        }
    }

    func previousWineSessionStillFinishing() -> Bool {
        if ideck_wineprocess_running() {
            setWindowsStatus("A Windows session is already running. Close it before starting another game.")
            return true
        }
        if ideck_wineprocess_thread_finished() && ideck_wineserver_running() {
            _ = ideck_wineserver_stop_if_idle()
        }
        let stillBusy = !ideck_wineprocess_running() &&
            (ideck_wineserver_running() || !ideck_wineprocess_thread_finished()) &&
            !waitForSessionCleanup()
        if stillBusy {
            setWindowsStatus(Self.cleanupStuckMessage)
            SteamLog.event("[wine-session] blocked second launch: worker/server still active")
            return true
        }
        if !ideck_wineprocess_running() {
            // The previous guest may have exited normally without the user
            // pressing Close. Re-arm native session state before the next
            // launch only after both worker and wineserver are quiescent.
            // The last guest thread and wineserver can take a moment to go
            // quiescent after the game window closes: wait for them (the run
            // loop keeps the UI responsive) instead of refusing the launch.
            if !ideck_runtime_complete_session() {
                setWindowsStatus("Waiting for the previous Windows session to finish…")
            }
            // Up to 20 s: a game's last threads and the wineserver can take that long to
            // stop after its window closes. Wine runs inside iDeck, so when they do not
            // stop, only reopening iDeck gives the next game a clean runtime.
            guard waitForSessionCleanup(timeout: 20) else {
                setWindowsStatus(Self.cleanupStuckMessage)
                SteamLog.event("[wine-session] cleanup did not finish within 20 s; launch refused, restart needed")
                return true
            }
        }
        if let why = Self.restartNeeded() {
            SteamLog.event("[wine-session] launch held, fresh iDeck process needed: \(why)")
            if !reopenWithFreeMemory(reason: "next launch needs a fresh process (\(why))", exitAnyway: false) {
                setWindowsStatus(jitMethod == "builtIn"
                    ? "Execution Error: \(why). Restart iDeck before starting another game: swipe iDeck away in the app switcher, then open it again; the built-in JIT turns on by itself."
                    : "Execution Error: \(why). Restart iDeck before starting another game: swipe iDeck away in the app switcher, then open it again through StikDebug.")
            }
            return true
        }
        return false
    }

    // A Windows guest runs as a thread inside the iDeck process. The only
    // safe normal shutdown is cooperative guest exit, followed by upstream
    // WineProcessBridge calling wineserver_stop(). Killing this PID would
    // terminate iDeck and all of its Steam library state.
    func requestCloseWindowsSession() {
        guard !isClosingWindowsSession else { return }
        isClosingWindowsSession = true
        cancelQueuedLaunches()
        onDemandInstallTask?.cancel()
        onDemandInstallTask = nil
        MainActor.assumeIsolated { ResourceGovernor.closingSession = true }
        windowsCloseWarning = nil
        windowsCloseWarningWasShown = false
        windowsCloseRequestedAt = ProcessInfo.processInfo.systemUptime
        windowsCloseAttempts = 0
        windowsStatusBeforeClose = windowsStatus
        pendingSteamGameID = nil
        setWindowsStatus("Closing Windows session...")
        if ideck_wineprocess_running() {
            if !ideck_wineprocess_request_close() {
                SteamLog.event("[wine-close] guest keyboard unavailable; waiting for native exit")
            } else {
                SteamLog.event("[wine-close] Alt+F4 requested; waiting for guest and wineserver")
            }
            // 2.13.1: the X only closes the game (Alt+F4, retried, then the close
            // warning). iDeck no longer reopens itself through StikDebug here: a
            // process that ran a Windows session is replaced when the NEXT game is
            // started (restartNeeded() in the launch path), not when one closes.
            AppLog.record("[wine-close] X pressed with a session running: waiting for the game to exit")
            SessionOutcome.ended("closed with the X button")
        }
        pollWindowsSessionClose()
    }

    func retryCloseWindowsSession() {
        windowsCloseWarning = nil
        windowsCloseWarningWasShown = false
        windowsCloseRequestedAt = ProcessInfo.processInfo.systemUptime
        windowsCloseAttempts = 0
        if ideck_wineprocess_running() {
            _ = ideck_wineprocess_request_close()
        }
        pollWindowsSessionClose()
    }

    /// The game did not exit: iDeck closes itself, the only way to end an in-process
    /// Wine thread that ignores Alt+F4 (Madeira offers the same). StikDebug is not
    /// opened here: the next game started after iDeck is opened again asks for JIT.
    func forceCloseIDeck() {
        SteamLog.event("[wine-close] game did not exit; iDeck closed by the user")
        AppLog.record("[wine-close] force close: iDeck exits so the stuck Windows session ends")
        SessionOutcome.ended("the game did not exit; iDeck was closed from the close warning")
        finishMemorySampling(reason: "the game did not exit; iDeck was force-closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exit(0) }
    }

    /// Ends this iDeck process and has StikDebug open a new one, so the next game or
    /// app starts with all memory free (Wine runs inside iDeck; a process that ran a
    /// Windows session keeps memory a second one cannot get back). With StikDebug
    /// the new process comes up with JIT and prepares its pool at once; without it
    /// (built-in JIT, or StikDebug missing) iDeck only exits and is opened again by
    /// hand. `exitAnyway` false keeps this process when StikDebug cannot be opened.
    @discardableResult
    func reopenWithFreeMemory(reason: String, exitAnyway: Bool = true) -> Bool {
        let canRelaunch = jitMethod != "builtIn" && StikJITHelper.isAvailable && StikJITHelper.scriptData != nil
        guard canRelaunch else {
            AppLog.record("[relaunch] \(reason): StikDebug cannot reopen iDeck here"
                          + (exitAnyway ? "; iDeck exits, open it again" : "; kept running"))
            if exitAnyway { exit(0) }
            return false
        }
        AppLog.record("[relaunch] \(reason): StikDebug opens a new iDeck with the memory free "
                      + "(available now \(Int(os_proc_available_memory() >> 20)) MiB)")
        setWindowsStatus("Freeing memory: iDeck reopens through StikDebug…")
        StikJITHelper.requestFreshInstance { opened in
            DispatchQueue.main.async {
                if opened {
                    // Gone before StikDebug launches the new process.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
                    return
                }
                UserDefaults.standard.removeObject(forKey: StikJITHelper.relaunchRequestedAtKey)
                AppLog.record("[relaunch] StikDebug could not be opened" + (exitAnyway ? "; iDeck exits" : ""))
                if exitAnyway { exit(0) }
                self.setWindowsStatus(Self.restartMessage)
            }
        }
        return true
    }

    /// Logs, once per process, that this one was opened by reopenWithFreeMemory.
    static func noteFreshInstanceAfterRelaunch() {
        let key = StikJITHelper.relaunchRequestedAtKey
        let at = UserDefaults.standard.double(forKey: key)
        guard at > 0 else { return }
        UserDefaults.standard.removeObject(forKey: key)
        let seconds = Date().timeIntervalSince1970 - at
        guard seconds >= 0, seconds < 300 else { return }
        AppLog.record("[relaunch] new iDeck process \(String(format: "%.1f", seconds)) s after the reopen request "
                      + "(available \(Int(os_proc_available_memory() >> 20)) MiB)")
    }

    func acknowledgeWindowsCloseWarning() {
        windowsCloseWarning = nil
    }

    func cancelWindowsSessionClose() {
        guard isClosingWindowsSession else { return }
        isClosingWindowsSession = false
        windowsCloseRequestedAt = nil
        windowsCloseAttempts = 0
        windowsCloseWarning = nil
        windowsCloseWarningWasShown = false
        let previousStatus = windowsStatusBeforeClose
        windowsStatusBeforeClose = nil
        if ideck_wineprocess_running() || ideck_wineserver_running() {
            setWindowsStatus(previousStatus ?? "Wine started; waiting for game...")
        } else {
            isClosingWindowsSession = true
            finishWindowsSessionCloseIfPossible()
        }
    }

    func pollWindowsSessionClose() {
        guard isClosingWindowsSession else { return }
        if !ideck_wineprocess_running() && ideck_wineprocess_thread_finished() &&
           ideck_wineserver_running() {
            // The guest may have failed before its thread was created,
            // leaving an orphan wineserver. Stop only that idle server on
            // a background queue, not the Wine worker or the iDeck process.
            _ = ideck_wineserver_stop_if_idle()
        }
        if !ideck_wineprocess_running() && !ideck_wineserver_running() &&
           ideck_wineprocess_thread_finished() {
            finishWindowsSessionCloseIfPossible()
            return
        }
        let seconds = ProcessInfo.processInfo.systemUptime - (windowsCloseRequestedAt ?? 0)
        // Some games drop the first Alt+F4 while creating their window, and
        // launchers can transfer focus to a child process. Retry normal,
        // cooperative close at most three times; never cancel/kick the Wine
        // pthread or kill the iDeck host process.
        if ideck_wineprocess_running() && windowsCloseAttempts < 3 &&
           seconds >= Double((windowsCloseAttempts + 1) * 4) {
            windowsCloseAttempts += 1
            let delivered = ideck_wineprocess_request_close()
            SteamLog.event("[wine-close] retry=\(windowsCloseAttempts) alt-f4=\(delivered)")
        }
        if seconds >= 15, !windowsCloseWarningWasShown {
            windowsCloseWarningWasShown = true
            windowsCloseWarning = "The Windows game has not exited. Close it from its own menu, retry, or close iDeck: unsaved progress is lost."
            SteamLog.event("[wine-close] guest or wineserver did not exit after 15 seconds")
        }
    }

    func finishWindowsSessionCloseIfPossible() {
        if activeSteamInstallerAppID != nil {
            _ = finishSteamPrerequisiteSession()
            return
        }
        guard !ideck_wineprocess_running(), !ideck_wineserver_running(),
              ideck_wineprocess_thread_finished(),
              ideck_runtime_complete_session() else { return }
        finishMemorySampling(reason: "closed from iDeck")
        activeSteamGameID = nil
        activeSteamPrefix = nil
        pendingSteamGameID = nil
        activeWindowsProfile = nil
        releaseSessionResources()
        isClosingWindowsSession = false
        windowsCloseRequestedAt = nil
        windowsCloseWarning = nil
        windowsCloseWarningWasShown = false
        windowsStatusBeforeClose = nil
        SteamLog.event("[wine-close] Wine and wineserver exited; returning to Steam library")
        setWindowsStatus("Windows Ready")
        // 2.13.1: nothing more here. A process that ran a Windows session cannot start
        // another one; StikDebug opens a fresh iDeck when the next game is started
        // (restartNeeded() in the launch path), not as soon as this one closes.
    }

    func refreshWindowsSessionHealth() {
        if let appID = activeSteamInstallerAppID {
            _ = appID
            steamPrerequisiteProgress = MainActor.assumeIsolated { DockInstallers.poll(drive: MadeiraDock.drive) }
                ?? steamPrerequisiteProgress
            if !ideck_wineprocess_running() {
                if ideck_wineserver_running() && ideck_wineprocess_thread_finished() {
                    _ = ideck_wineserver_stop_if_idle()
                }
                _ = finishSteamPrerequisiteSession()
            }
            return
        }
        guard windowsStatus == "Running" || windowsStatus == "Steam Running" ||
              windowsStatus == "Wine started; waiting for game..." else { return }
        guard !ideck_wineprocess_running() else { return }
        let endedGame = activeWindowsProfile?.id ?? activeSteamGameID.map { "steam:\($0)" }
        activeSteamGameID = nil
        activeSteamPrefix = nil
        pendingSteamGameID = nil
        defer { releaseSessionResources() }
        // Madeira Dock writes its result (sign-in, license, offline checks)
        // and exits at once, often between two one-second report polls. Read
        // the report a last time: its reason beats Wine's bare exit code
        // (code 34, for one, means Steam did not finish signing in).
        if dockSessionActive {
            dockSessionActive = false
            let report = MainActor.assumeIsolated { MadeiraDock.pollReport() }
            MainActor.assumeIsolated { MadeiraDock.cleanup() }
            if let failure = report.failure {
                SteamLog.event("[wine-exit] Steam: \(failure)")
                LaunchReport.finish(game: endedGame ?? "unknown", reason: "Steam: " + failure, ntstatus: nil, runtimeTrap: false)
                finishMemorySampling(reason: "Steam: " + failure, game: endedGame)
                if let endedGame { GameCompatibility.noteSessionEnd(endedGame, ntstatus: nil, reason: "Steam: " + failure) }
                setWindowsStatus("Steam: " + failure)
                return
            }
        }
        var outcome = wineExitResult()
        // EA app games that close by themselves (licence, anti-cheat, missing EA app)
        // used to return to the library with no word: say what went wrong and keep
        // the session screen open on it.
        if let endedGame, endedGame.hasPrefix("ea:"), !outcome.reason.hasPrefix("Execution Error") {
            let seconds = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if let ea = Self.eaFailureReason(logURL: Self.wineLogURL, since: wineLogStartOffset, seconds: seconds) {
                outcome.reason = ea
            }
        }
        sessionStartedAt = nil
        // A Steam game started without Steam's client that asked for it and closed
        // (SteamAPI_RestartAppIfNecessary: steam://run/<app>, then exit code 0).
        if let endedGame, endedGame.hasPrefix("steam:"), let started = directSteamStartedAt,
           let appID = UInt32(endedGame.dropFirst("steam:".count)),
           Date().timeIntervalSince(started) < SteamClientNeed.quickExitSeconds,
           Self.sessionLogContains(SteamClientNeed.markers(appID: appID), logURL: Self.wineLogURL, since: wineLogStartOffset) {
            SteamClientNeed.note(appID)
            outcome.reason = "Execution Error: " + "The game needs Steam's Windows client. It asked for Steam and closed, so iDeck starts it through Steam from now on. Start it again."
        }
        directSteamStartedAt = nil
        // A program that stopped on a missing DLL (0xC0000135), a DLL of the wrong
        // architecture (0xC000007B) or a crash, when the check before it found a cause.
        if let check = DependencyCheck.last, check.problems,
           outcome.ntstatus == 0xC0000135 || outcome.ntstatus == 0xC000007B || outcome.reason.hasPrefix("Execution Error") {
            outcome.reason += " DLL check before the start: " + check.summary + "."
        }
        DependencyCheck.last = nil
        // iDeck Auto DLL Manager: a DLL the start failed on (c0000135) that an official
        // component ships is downloaded now and put in place at the next start.
        if outcome.ntstatus == 0xC0000135 || outcome.reason.hasPrefix("Execution Error"),
           let program = AutoDLLManager.lastProgram {
            let dlls = AutoDLLManager.missingInLog(Self.wineLogURL, since: wineLogStartOffset)
            if !dlls.isEmpty {
                AutoDLLManager.notePending(dlls, program: program)
                outcome.reason += " " + "iDeck is getting the missing DLLs (" + dlls.joined(separator: ", ") + ") from Microsoft: start the game again."
            }
        }
        // Metal GPU faults (hang, timeout, ignored submissions): the heaviest GPU work
        // iDeck adds goes for this game, and the next launch runs one frame in flight.
        if let endedGame {
            let faulted = Self.sessionLogContains(GPUFaultGuard.markers, logURL: Self.wineLogURL, since: wineLogStartOffset)
            if GPUFaultGuard.note(endedGame, faulted: faulted) {
                let lightened = MainActor.assumeIsolated { () -> Bool in
                    let store = WindowsLibraryStore()
                    guard var profile = store.profiles[endedGame], profile.metalFXEnabled || profile.frameGeneration else { return false }
                    profile.metalFXEnabled = false
                    profile.frameGeneration = false
                    store.save(profile)
                    return true
                }
                if lightened {
                    outcome.reason += " " + "The GPU reported errors during this session: MetalFX and frame generation are now off for this game."
                }
                SteamLog.event("[gpu-fault] \(endedGame): GPU errors in the Wine log; lighter GPU settings from the next launch")
            }
        }
        let hostTrap = outcome.ntstatus == 0xC000001D
            && IllegalInstructionOrigin.isHost(logURL: Self.wineLogURL, since: wineLogStartOffset)
        let shaderFailure = Self.sessionLogShowsShaderFailure(logURL: Self.wineLogURL, since: wineLogStartOffset)
        if let endedGame, Self.sessionLogContains(FullCodeChecksAuto.markers.map { $0.lowercased() },
                                                  logURL: Self.wineLogURL, since: wineLogStartOffset) {
            FullCodeChecksAuto.enable(endedGame)
        }
        EALibrary.noteSessionEnded(activationUI: Self.sessionLogContains(["activationui.exe"], logURL: Self.wineLogURL,
                                                                        since: wineLogStartOffset))
        wineLogStartOffset = nil
        let ntstatus = outcome.ntstatus
        var reason = outcome.reason
        // An illegal instruction (0xC000001D) is what a game built for AVX
        // processors hits without AVX translation: it is turned on for that game.
        // One raised by the Windows runtime's own code is not the game's: AVX
        // translation would change nothing, so it stays as the user set it.
        if hostTrap {
            reason = "Execution Error: Windows program crashed (NTSTATUS 0xC000001D). "
                + "The Windows runtime stopped on an internal error while starting this game; "
                + "AVX/AVX2 translation is unrelated and was left unchanged."
            SteamLog.event("[avx] 0xC000001D came from the runtime, not from guest code: AVX left unchanged")
        } else if ntstatus == 0xC000001D, let endedGame, AVXAuto.enable(endedGame) {
            reason += " AVX/AVX2 translation is now on for this game: restart iDeck and start it again."
        }
        if shaderFailure, let executable = lastPreparedExecutable, !NativeD3DX.installed(for: executable) {
            NativeD3DX.noteShaderFailure(executable)
            satisfiedExecutables[executable.path] = nil
            reason += " The game could not compile a shader with Wine's D3DX: Microsoft's D3DX 9 is installed for it at its next start."
        }
        SteamLog.event("[wine-exit] \(reason)")
        LaunchReport.finish(game: endedGame ?? "unknown", reason: reason, ntstatus: ntstatus, runtimeTrap: hostTrap)
        finishMemorySampling(reason: reason, game: endedGame)
        if let endedGame { GameCompatibility.noteSessionEnd(endedGame, ntstatus: ntstatus, reason: reason) }
        Self.reclaimAfterSession()
        if let ntstatus, ntstatus != 0 { Self.restartReason = "the last game crashed (NTSTATUS 0x\(String(ntstatus, radix: 16, uppercase: true)))" }
        setWindowsStatus(reason)
    }

    /// Windows' temporary folders (C:\\windows\\temp and each user's AppData\\Local\\Temp)
    /// emptied of what earlier sessions left, once no Windows program runs. Files the
    /// session that just ended wrote stay until the next cleanup, for an installer
    /// that continues after a restart. In the background; logged as [session-temp].
    static func cleanWindowsTemp(before cutoff: Date) {
        guard cutoff > .distantPast else { return }
        let drive = MadeiraDock.drive
        DispatchQueue.global(qos: .utility).async {
            guard !ideck_wineprocess_running() else { return }
            let fm = FileManager.default
            var folders = [drive.appendingPathComponent("windows/temp")]
            let users = drive.appendingPathComponent("users")
            for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
                folders.append(users.appendingPathComponent(user).appendingPathComponent("AppData/Local/Temp"))
                folders.append(users.appendingPathComponent(user).appendingPathComponent("Temp"))
            }
            var removed = 0, bytes: Int64 = 0
            for folder in folders {
                let resolved = folder.resolvingSymlinksInPath()
                // Only real folders inside the prefix: a link elsewhere is never emptied.
                guard resolved.path.hasPrefix(drive.resolvingSymlinksInPath().path + "/"),
                      let entries = try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { continue }
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey])
                    guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
                    let size = Int64(values?.totalFileAllocatedSize ?? 0)
                    if (try? fm.removeItem(at: entry)) != nil { removed += 1; bytes += size }
                }
            }
            if removed > 0 { AppLog.record("[session-temp] removed \(removed) item(s), \(bytes >> 20) MB, left in Windows' temporary folders by earlier sessions") }
        }
    }

    private func releaseSessionResources() {
        activeWindowsProfile = nil
        URLCache.shared.removeAllCachedResponses()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GOGGalaxy.shared.stop()
                if !ideck_wineprocess_running() { MadeiraDock.cleanup() }
                NotificationCenter.default.post(name: ResourceGovernor.releaseCachesNotification, object: nil)
            }
        }
        Self.cleanWindowsTemp(before: sessionTempCutoff)
        AppLog.record("[session] resources released after the session "
                      + "(available \(Int(os_proc_available_memory() >> 20)) MiB)")
    }

    /// Whether the session's part of the Wine log (its last 16 MB at most) names a
    /// shader the game wrote to ShaderErrors after a failed compile.
    static func sessionLogShowsShaderFailure(logURL: URL?, since offset: Int64?) -> Bool {
        sessionLogContains(["\\shadererrors\\compileerror", "\\\\shadererrors\\\\compileerror"], logURL: logURL, since: offset)
    }

    /// Whether this session's Wine log (its last 16 MB) contains any of the lower-case needles.
    static func sessionLogContains(_ lowercaseNeedles: [String], logURL: URL?, since offset: Int64?) -> Bool {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return false }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = max(UInt64(max(offset ?? 0, 0)), end > 16 << 20 ? end - (16 << 20) : 0)
        try? handle.seek(toOffset: start)
        // Searched as bytes, 1 MB at a time with a short overlap, ASCII-lowercased in
        // place: no 16 MB String is built and no case-insensitive Unicode search runs.
        let needles = lowercaseNeedles.map { Data($0.utf8) }
        let overlap = needles.map(\.count).max() ?? 0
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            var window = carry + chunk
            window.withUnsafeMutableBytes { raw in
                for i in raw.indices where raw[i] >= 0x41 && raw[i] <= 0x5A { raw[i] |= 0x20 }
            }
            if needles.contains(where: { window.range(of: $0) != nil }) { return true }
            carry = window.suffix(overlap)
        }
        return false
    }

    /// Returns an exited 32-bit program's 4 GB window to iOS as soon as the session
    /// has really ended, instead of when the next 32-bit program starts. Waits (on a
    /// background thread, never a Wine one) up to 30 s for the worker to finish and the
    /// wineserver to stop; the native side still refuses while any of the program's
    /// threads exists. The JIT pool stays.
    static func reclaimAfterSession() {
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<60 {
                if !ideck_wineprocess_running() && ideck_wineprocess_thread_finished() && !ideck_wineserver_running() { break }
                usleep(500_000)
            }
            let before = Int(os_proc_available_memory() >> 20)
            let waiting = ideck_wow_reclaim_after_session()
            let after = Int(os_proc_available_memory() >> 20)
            AppLog.record("[memory] after-session reclaim: \(waiting < 0 ? "not run (session still active or unavailable)" : "\(waiting) window(s) still waiting"), "
                          + "\(before) -> \(after) MiB available")
        }
    }

    /// A mapping other than iDeck's own PROT_NONE reservation inside the executable
    /// window [0x140000000, 0x148000000), described for the log; nil when it is free.
    static func executableWindowUse() -> String? {
        let start: vm_address_t = 0x1_4000_0000, end: vm_address_t = 0x1_4800_0000
        var address = start
        while address < end {
            var size: vm_size_t = 0
            var info = vm_region_basic_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
            var object: mach_port_t = 0
            var region = address
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    vm_region_64(mach_task_self_, &region, &size, VM_REGION_BASIC_INFO_64, $0, &count, &object)
                }
            }
            guard kr == KERN_SUCCESS, region < end else { return nil }
            if info.protection != 0 {
                return String(format: "0x%lx+%luKB prot %d", Int(region), Int(size >> 10), Int(info.protection))
            }
            address = region + size
        }
        return nil
    }

    static func restartNeeded() -> String? {
        if let restartReason { return restartReason }
        if WindowsEnvironment.oneSessionPerRun && WindowsEnvironment.sessionsThisRun > 0 {
            return "this runtime requires a fresh iDeck process for each Windows session"
        }
        // A fixed-base program needs [0x140000000, +128MB). iDeck holds it as a PROT_NONE
        // reservation; a readable or writable mapping there means earlier work in this
        // process (a long download) took part of it, and the game would stop with
        // "failed to create main module ... c0000018" (Dragon Age: Inquisition after a
        // 34 GB download in the same process).
        if let used = executableWindowUse() {
            // Once per 3 minutes: a fresh process that still shows it must not reopen forever.
            let key = "relaunch.exeWindowAt"
            let last = UserDefaults.standard.double(forKey: key)
            let now = Date().timeIntervalSince1970
            if now - last > 180 {
                UserDefaults.standard.set(now, forKey: key)
                return "the executable address window is in use (\(used))"
            }
            AppLog.record("[exe-window] still in use after a reopen (\(used)); starting anyway")
        }
        // A pool that had to shrink is not a reason: it happens on a fresh launch too
        // (the startup pool keeps a 256 MB exe window free), so reopening changes nothing.
        let free = Int(os_proc_available_memory() >> 20)
        if free > 0 && free < restartMinimumFreeMiB { return "only \(free) MB of memory is left" }
        return nil
    }
}
