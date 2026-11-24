import Foundation
import Combine
import UIKit
import QuartzCore
import Darwin

class SystemCoordinator: ObservableObject {
    @Published var isJITEnabled: Bool = false
    @Published var isStikDebugAttached: Bool = false
    @Published var isWineJITPrepared: Bool = false
    @Published var isContainerReady: Bool = false
    @Published var currentStatus: String = "Ready"
    @Published var windowsStatus: String = "Ready"
    @Published var isSteamConnected: Bool = false
    @Published var hasPairingFile: Bool = false
    
    @Published var isMaxRefreshRateEnabled: Bool = false {
        didSet {
            applyMaxRefreshRate()
        }
    }
    
    let jitEnabler = JITEnabler()
    let prefixHost = MadeiraPrefixHost()
    let windowsEnvironment = WindowsEnvironment()
    let prefixInstaller = PrefixInstaller()
    private var displayLink: CADisplayLink?
    private var steamSignInObserver: NSObjectProtocol?
    private var steamSignInLoaded = false
    private var activeSteamGameID: UInt32?
    /// A Madeira Dock (Steam client) session is running; its final report is
    /// read when Wine exits.
    private var dockSessionActive = false
    // The Wine host can return 0 after a Steam-launched game child aborts.
    // Only inspect Wine fatal-crash lines written after the current launch.
    private var wineLogStartOffset: Int64?
    /// The program the last launch prepared (prepareVisualCRuntimeIfNeeded), for what a
    /// session's log says about it afterwards.
    private var lastPreparedExecutable: URL?

    private static var wineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.txt", isDirectory: false)
    }

    /// madeira-log.txt grows by every session (Madeira opens it for appending) and was
    /// never cut. Between sessions, while no Wine runs, a log past this size is kept
    /// as madeira-log.previous.txt.lzfse (one kept: repeated lines folded, then
    /// compressed), so the current log stays small and fast to scan and copy.
    static let wineLogRotateBytes: Int64 = 8 << 20

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

    private func captureWineLogStart() {
        guard let url = Self.wineLogURL else {
            wineLogStartOffset = nil
            return
        }
        Self.rotateWineLogIfLarge(url)
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        wineLogStartOffset = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func wineExitResult() -> (reason: String, ntstatus: UInt32?) {
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
    private var activeSteamInstallerAppID: UInt32?
    private var steamDockStartedAt: TimeInterval?
    @Published private(set) var steamPrerequisiteProgress: String?
    @Published private(set) var steamDockLaunchStage: String?
    @Published private(set) var currentSteamLaunchUsesDock = false
    @Published private(set) var dockLaunchAccepted = false
    /// Whether the current (or last) Wine session is a game installed by
    /// Steam. Errors that mention Steam are shown only for those sessions.
    /// Kept across launches so Bugs & logs can tell what the last run was.
    @Published private(set) var isSteamSession: Bool = UserDefaults.standard.bool(forKey: "session.lastWasSteam") {
        didSet { UserDefaults.standard.set(isSteamSession, forKey: "session.lastWasSteam") }
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

    private func recordGameContext(_ title: String, launcher: String) {
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

    private var memorySampler: Timer?
    private var finishMemorySample: ((String, String?) -> Void)?

    /// Ends the session's memory record: current, peak and available memory and
    /// why the session ended, logged and kept for Bugs & logs (SessionMemory).
    private func finishMemorySampling(reason: String = "session ended", game: String? = nil) {
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

    @Published private(set) var activeWindowsProfile: WindowsGameProfile? {
        // The game the JIT pool is prepared for (MadeiraWinePool reads it to size the
        // pool from what GameCompatibility learned about this game).
        didSet {
            if let id = activeWindowsProfile?.id { setenv("IDECK_COMPAT_GAME", id, 1) }
            else if oldValue != nil { unsetenv("IDECK_COMPAT_GAME") }
        }
    }
    private var activeSteamPrefix: String?
    private var pendingSteamGameID: UInt32?
    @Published private(set) var isClosingWindowsSession = false
    @Published private(set) var windowsCloseWarning: String?
    private var windowsCloseRequestedAt: TimeInterval?
    private var windowsCloseWarningWasShown = false
    private var windowsCloseAttempts = 0
    private var windowsStatusBeforeClose: String?
    private var wineJITPreparationInFlight = false
    private var wineJITAttemptedDuringAttachment = false
    @Published var needsVisualCRuntimeConsent = false
    private var visualCRuntimeConsentAction: (() -> Void)?
    private var visualCRuntimeSkipAction: (() -> Void)?
    private var bypassVisualCRuntimeForPrefix: String?

    private static let supportedWineJITPoolMiB: Set<Int> = [64, 96, 128, 192, 256, 384, 512, 560, 624, 640, 768, 896, 1152]

    /// The pool size that last prepared successfully on this device: the
    /// native side starts there instead of retrying larger sizes the
    /// debugger cannot allocate. Choosing a size in Settings resets it.
    /// v2: sizes saved before the early placeholder was released (#150)
    /// reflect the blocked layout, not the device, and are ignored.
    private static let lastGoodPoolKey = "wineJITPoolLastGoodMiB.v2"

    private static func exportLastGoodPool() {
        let size = UserDefaults.standard.integer(forKey: lastGoodPoolKey)
        if size > 0 { setenv("IDECK_WINE_JIT_LAST_GOOD_MIB", String(size), 1) }
        else { unsetenv("IDECK_WINE_JIT_LAST_GOOD_MIB") }
    }

    private static func exportWineJITPreference(_ sizeMiB: Int) {
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

    init() {
        MainActor.assumeIsolated {
            ResourceGovernor.shared.onActivityChange = { [weak self] in self?.applyMaxRefreshRate() }
            ResourceGovernor.shared.start()
        }
        // 896 MB was the old default and never fits beside the game on these
        // devices (the start stopped while reserving it): saved once as 624.
        if UserDefaults.standard.object(forKey: "wineJITPoolMiB") as? Int == 896,
           !UserDefaults.standard.bool(forKey: "wineJITPool624Migrated") {
            UserDefaults.standard.set(624, forKey: "wineJITPoolMiB")
        }
        UserDefaults.standard.set(true, forKey: "wineJITPool624Migrated")
        // 624 MB never fits beside the main thread's stack on these devices: every
        // launch shrank it to 560 MB (ml1036). Saved 624 values move to 560 once.
        if UserDefaults.standard.object(forKey: "wineJITPoolMiB") as? Int == 624,
           !UserDefaults.standard.bool(forKey: "wineJITPool560Migrated") {
            UserDefaults.standard.set(560, forKey: "wineJITPoolMiB")
        }
        UserDefaults.standard.set(true, forKey: "wineJITPool560Migrated")
        Self.exportWineJITPreference(UserDefaults.standard.object(forKey: "wineJITPoolMiB") as? Int ?? 560)
        Self.exportLastGoodPool()
        // Keep app startup free of native Wine/JIT probes and Keychain reads.
        // In particular, a CS_DEBUGGED flag left behind by StikDebug or a
        // previous Wine crash must not be used to initialize FEX on app open.
        // The Madeira workspace explicitly asks for these checks on entry.
        steamSignInObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.steamSignInLoaded = true
            self.isSteamConnected = SteamSignIn.isSignedIn
            self.installSteamClientComponentsIfNeeded()
        }
    }

    /// The installer's latest message while components download for a launch.
    @Published var steamComponentsProgress: String?
    private var steamComponentsTask: Task<Void, Never>?
    /// Valve's client components are being fetched (the initial setup waits on it).
    var steamComponentsInstalling: Bool { steamComponentsTask != nil }
    private var dockInstallAfterPrefix = false
    private var isPreparingWindowsPrefix = false

    /// Explicitly requested from onboarding. Unlike background repair, a tap
    /// always returns visible feedback and can initialize the prefix first.
    func installMadeiraDock() {
        guard MadeiraDock.bundled else {
            steamComponentsProgress = "Madeira Dock is missing from this IPA."
            return
        }
        if !PrefixInstaller.isPrefixInstalled(at: MadeiraDock.prefix) {
            steamComponentsProgress = "Preparing x64 + x86 Wine environment…"
            dockInstallAfterPrefix = true
            openMadeiraWorkspace()
            return
        }
        installSteamClientComponentsIfNeeded(force: true)
    }

    /// Madeira Dock needs Valve's client components in the prefix. They are
    /// fetched once, in the background, as soon as a Steam account is signed
    /// in and the Wine prefix exists (again on the next library visit if not).
    func installSteamClientComponentsIfNeeded(force: Bool = false) {
        // Expose the import folder through Files without touching running
        // sessions or re-creating it on every library refresh.
        if MadeiraDock.bundled, let folder = SteamDLLRepair.sourceFolder,
           !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Madeira 0.2.0: prepare WineHQ's pinned Gecko MSI installers in
        // WINEPREFIX/.cache/wine on Wi-Fi only. This is independent of the
        // Steam client and avoids Wine's in-guest Gecko download dialog.
        if MadeiraDock.bundled, PrefixInstaller.isPrefixInstalled(at: MadeiraDock.prefix) {
            WineGeckoRuntime.prepareInBackground(prefix: MadeiraDock.prefix)
        }
        // Runs when the Madeira workspace first opens (its Wine prefix
        // ready), with or without a Steam account: the components come from
        // Valve's public update server.
        // A setup already under way keeps its own progress line: a second tap must not
        // replace it with a message about Wine.
        guard steamComponentsTask == nil else { return }
        guard MadeiraDock.bundled,
              PrefixInstaller.isPrefixInstalled(at: MadeiraDock.prefix),
              !ideck_wineprocess_running(), !ideck_wineserver_running() else {
            if force { steamComponentsProgress = "Dock setup is unavailable while Wine is running or its prefix is not ready." }
            return
        }
        // The pinned Valve installer does not guarantee the optional video
        // codecs. Repair an already installed client as well, without
        // restarting Wine or copying large DLLs on the UI thread. The downloaded
        // DLLs stay in Documents/SteamDLLs after they are installed, so their
        // presence alone is not work to do: only a client that still lacks one is.
        guard !MadeiraDock.clientInstalled || SteamDLLRepair.needsRepair(prefix: MadeiraDock.prefix) else {
            if force { steamComponentsProgress = "Madeira Dock is already installed." }
            return
        }
        steamComponentsProgress = "Installing Madeira Dock components…"
        steamComponentsTask = Task(priority: .utility) { @MainActor [weak self] in
            do {
                if !MadeiraDock.clientInstalled {
                    try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("wine", isDirectory: true)) { [weak self] message in
                        AppLog.record("[steam-components] " + message)
                        await self?.publishSteamComponentsProgress(message)
                    }
                    guard MadeiraDock.clientInstalled else {
                        throw DockError.message("Madeira Dock installation finished without steamclient64.dll.")
                    }
                }
                let prefix = MadeiraDock.prefix
                if SteamDLLRepair.needsRepair(prefix: prefix) {
                    // Valve's official x64 video DLLs and SDL3.dll, pinned by SHA-256.
                    do {
                        try await SteamVideoLibraries.fetch { [weak self] message in
                            AppLog.record("[steam-dll] " + message)
                            await self?.publishSteamComponentsProgress(message)
                        }
                    } catch {
                        AppLog.record("[steam-dll] official Steam DLL download failed: \(error.localizedDescription)")
                    }
                }
                let report = await Task.detached(priority: .utility) {
                    SteamDLLRepair.repair(prefix: prefix)
                }.value
                if !report.copied.isEmpty {
                    AppLog.record("[steam-dll] repaired: " + report.copied.joined(separator: ", "))
                }
                if !report.invalid.isEmpty {
                    AppLog.record("[steam-dll] incompatible or unsafe files preserved: "
                                  + report.invalid.joined(separator: ", "))
                }
                if !report.missing.isEmpty {
                    AppLog.record("[steam-dll] Steam video client is missing: "
                                  + report.missing.joined(separator: ", ")
                                  + "; retry Madeira Dock setup or import genuine Steam x64 DLLs into Documents/SteamDLLs")
                }
                self?.steamComponentsProgress = report.missing.isEmpty
                    ? "Madeira Dock installed and verified."
                    : "Madeira Dock installed. Optional Steam video DLLs are missing: " + report.missing.joined(separator: ", ")
            } catch {
                let message = "Madeira Dock installation failed: \(error.localizedDescription)"
                self?.steamComponentsProgress = message
                AppLog.record("[steam-components] " + message)
            }
            self?.steamComponentsTask = nil
        }
    }

    @MainActor private func publishSteamComponentsProgress(_ message: String) {
        steamComponentsProgress = message
    }

    func loadSteamAccountIfNeeded() {
        guard !steamSignInLoaded else { return }
        steamSignInLoaded = true
        isSteamConnected = SteamSignIn.isSignedIn
        if isSteamConnected {
            // Rank CM servers while the library view loads, so the first
            // Steam request does not wait for the directory round trip.
        }
    }

    
    func setWindowsStatus(_ status: String) {
        AppLog.record("[status] " + status)
        SessionOutcome.status(status)
        recordBenchmarkMilestone(status)
        let update = {
            if status == "Windows Ready" || status.hasPrefix("Execution Error") || status.hasPrefix("Cannot launch") {
                self.finishMemorySampling(reason: status == "Windows Ready" ? "the game exited and Wine closed normally" : status)
                MainActor.assumeIsolated { EALibrary.shared.launchEnded() }
                self.releaseJITPoolAfterSession()
            }
            self.windowsStatus = status
            self.currentStatus = status
            // A session starting or ending changes whether 120 Hz may be held.
            self.applyMaxRefreshRate()
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    /// Benchmark milestones and the end of a game session, from its status.
    private func recordBenchmarkMilestone(_ status: String) {
        switch status {
        case "Wine started; waiting for game...": BenchmarkSession.mark("wine_started")
        case "Running", "Steam Running": BenchmarkSession.mark("running")
        case "Windows Ready":
            DispatchQueue.main.async { MainActor.assumeIsolated { ResourceGovernor.closingSession = false } }
            BenchmarkSession.finish(kind: "game", outcome: "closed")
            DispatchQueue.main.async { MainActor.assumeIsolated { SteamOwnedGamesModel.shared.releaseDock() } }
            if WindowsEnvironment.sessionsThisRun > 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { ResourceGovernor.shared.releaseAfterSession() } }
            }
        default:
            if status.hasPrefix("Execution Error") || status.hasPrefix("Cannot launch") {
                DispatchQueue.main.async { MainActor.assumeIsolated { SteamOwnedGamesModel.shared.releaseDock() } }
                BenchmarkSession.finish(kind: "game", outcome: "failed: " + status)
            }
        }
    }

    func refreshJITStatus() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let debuggerAttached = result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
        // Query code-signing status without allocating executable memory.
        // Repeated MAP_JIT probes can race with FEX memory initialization and
        // do not establish that StikDebug's BRK handler is ready.
        let detected = ideck_process_has_jit_permission() || debuggerAttached
        // The native prepare function owns the pool mutex while issuing BRK
        // requests. Do not block SwiftUI refreshes waiting for that mutex.
        // ideck_jit_snapshot only try-locks: while any preparation (this
        // one or a game launch's) holds the pool, keep the last known state
        // instead of blocking the main thread for the debugger round trips.
        let snapshot = ideck_jit_snapshot()
        let wineReady = (wineJITPreparationInFlight || snapshot.wine_state_busy)
            ? isWineJITPrepared : snapshot.wine_pool_prepared
        let update = { [weak self] in
            guard let self else { return }
            if self.isJITEnabled != detected { self.isJITEnabled = detected }
            if self.isStikDebugAttached != debuggerAttached { self.isStikDebugAttached = debuggerAttached }
            if self.isWineJITPrepared != wineReady { self.isWineJITPrepared = wineReady }
            // Wine's RX/RW pool must be allocated while StikDebug is actively
            // servicing the Madeira BRK protocol. A persisted JIT entitlement
            // alone does not authorize safely entering jit26_prepare_region.
            if !debuggerAttached {
                self.wineJITAttemptedDuringAttachment = false
            } else if detected && !wineReady &&
                      !self.wineJITPreparationInFlight &&
                      !self.wineJITAttemptedDuringAttachment {
                // iDeck opened by StikDebug: prepare Wine's pool now, while the
                // debugger is attached. StikDebug may detach before the user taps
                // Play; with the pool ready, the launch no longer reopens StikDebug.
                self.wineJITAttemptedDuringAttachment = true
                if Self.restartNeeded() == nil, MadeiraBundleIdentity.isNative,
                   StikJITHelper.scriptData != nil, !ideck_wineprocess_running(),
                   !self.isClosingWindowsSession, !ideck_wineserver_running() {
                    self.wineJITPreparationInFlight = true
                    // No game is chosen yet, so its fixed-base exe cannot be measured
                    // (measureExecutableWindow): a 256 MB executable window is kept free
                    // instead of 128 MB (192 MB: 256 cost the pool 112 MB), which fits images
                    // such as Assassin's Creed Unity's ACU.exe (131 MB) and MapleStory.exe (183 MB).
                    if StikJITHelper.exeWindowAutoMB < Self.earlyExeWindowMB {
                        StikJITHelper.exeWindowAutoMB = Self.earlyExeWindowMB
                    }
                    Self.earlyPoolExeWindowMB = Self.earlyExeWindowMB
                    AppLog.record("[jit] debugger attached at startup: preparing the Wine JIT pool now "
                                  + "(executable window \(Self.earlyExeWindowMB) MB)")
                    DispatchQueue.global(qos: .userInitiated).async {
                        let failure = MadeiraWinePool.prepare()
                        DispatchQueue.main.async {
                            self.wineJITPreparationInFlight = false
                            if let failure { AppLog.record("[jit] early pool preparation failed: \(failure)") }
                            self.refreshJITStatus()
                            if let launch = self.takePendingJITLaunch() {
                                if let failure { self.setWindowsStatus("Execution Error: " + failure) }
                                else { launch() }
                            }
                        }
                    }
                }
            }
            if !detected && (self.currentStatus == "JIT confirmed via StikDebug" || self.currentStatus == "Ready") {
                self.currentStatus = "JIT not detected. Enable it in StikDebug and return to iDeck."
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Opening the Madeira library never requests JIT. Authorization is
    /// checked only after the user explicitly launches a Windows program.
    func openMadeiraWorkspace() {
        startWindows()
    }

    /// Avoid repeated StikDebug prompts when CS_DEBUGGED is already enabled
    /// for this iDeck PID. Permission alone does not prepare Wine's RX pool:
    /// that still requires a live BRK-capable debugger, and a failed RX
    /// allocation must be surfaced rather than disguised as a JIT prompt.
    /// The launch to continue once StikDebug is attached (set by the caller
    /// right before `ensureJITForGameLaunch()`), as Madeira's jitReadyForLaunch(then:).
    private var jitResume: (() -> Void)?
    private var jitWaitGeneration = 0

    /// The launch that continues when StikDebug reports the debugger attached
    /// (StikJITHelper.waitForDebugger), as Madeira's jitReadyForLaunch(then:).
    private var pendingJITLaunch: (() -> Void)?
    /// Raised by every close: a launch queued behind JIT preparation before it is
    /// stale and never starts Wine into a session that is being torn down.
    private var launchGeneration = 0
    private var pendingJITLaunchGeneration = 0

    private func waitForDebuggerThenResume(_ resume: @escaping () -> Void) {
        pendingJITLaunch = resume
        pendingJITLaunchGeneration = launchGeneration
    }

    /// The queued launch, or nil when none is queued or it may not run now: a close
    /// came after it, a session is closing, or Wine is already running.
    private func takePendingJITLaunch() -> (() -> Void)? {
        let launch = pendingJITLaunch
        pendingJITLaunch = nil
        guard let launch else { return nil }
        if pendingJITLaunchGeneration != launchGeneration || isClosingWindowsSession
            || ideck_wineprocess_running() {
            AppLog.record("[jit] queued launch dropped: the session was closed or Wine is running")
            return nil
        }
        return launch
    }

    /// Forgets every launch waiting on JIT (called when a session is closed).
    private func cancelQueuedLaunches() {
        launchGeneration &+= 1
        pendingJITLaunch = nil
        jitResume = nil
    }

    /// Madeira's readiness: StikJITHelper.ready (CS_DEBUGGED and a live
    /// debugger) or a pool already exported. The pool itself is allocated at
    /// launch (MadeiraWinePool), followed by Madeira's early detach.
    @discardableResult
    private func ensureJITForGameLaunch() -> Bool {
        // Like Madeira, a 63 GB address map (no extended virtual addressing, as on
        // iPhones signed with a free Apple ID) does not block the launch: the JIT
        // pool's RW alias then goes below the map's end (MADEIRA_RW_ALIAS_RETRY)
        // and the pool is capped (MadeiraWinePool). Only the increased memory limit
        // is required.
        if !AddressSpaceCheck.hasGuestWindow {
            AppLog.record("[address-space] standard address map, launching without the extended guest window (\(AddressSpaceCheck.diagnostics))")
        }
        let resume = jitResume
        jitResume = nil
        // Closing and launching never overlap: the close owns the runtime until
        // finishWindowsSessionCloseIfPossible, and a running Wine keeps its pool.
        if isClosingWindowsSession {
            AppLog.record("[jit] launch refused: the previous session is still closing")
            setWindowsStatus("Waiting for the previous Windows session to finish…")
            return false
        }
        if ideck_wineprocess_running() {
            setWindowsStatus("A Windows session is already running. Close it before starting another game.")
            return false
        }
        refreshJITStatus()
        // The StikDebug-compatible script iDeck sends (universal.jitscript) must be
        // in the app: without it, neither StikDebug nor the built-in path can prepare
        // Wine's pool, so nothing starts.
        guard StikJITHelper.scriptData != nil else {
            AppLog.record("[jit] universal.jitscript missing from the app; launch blocked")
            setWindowsStatus("JIT cannot be prepared: this iDeck build is missing its JIT script.")
            return false
        }
        // Validated preparation: CS_DEBUGGED on this process, and a live debugger to
        // answer the pool request or this run's pool already prepared. Anything less
        // never reaches Wine: iDeck starts the activation itself and the launch waits.
        if wineJITPreparationInFlight {
            if let resume { waitForDebuggerThenResume(resume) }
            return false
        }
        if Self.jitPreparationValidated() {
            Self.recordLaunchJITState()
            return true
        }
        // As Madeira: without a live debugger (none yet, or CS_DEBUGGED left
        // behind by an earlier attach, where no new authorization was requested
        // before) StikDebug is opened and the launch continues once it is attached.
        setWindowsStatus(ideck_process_has_jit_permission()
            ? "JIT is enabled, but Wine's executable RX pool is not prepared. Reconnecting StikDebug..."
            : "JIT is not enabled for this iDeck process. Opening StikDebug...")
        if let resume { waitForDebuggerThenResume(resume) }
        requestStikDebugJIT()
        return false
    }

    /// JIT is ready for a launch: CS_DEBUGGED is set and the pool is prepared or a
    /// debugger is attached to prepare it.
    /// The executable window kept free by the pool prepared at startup.
    static let earlyExeWindowMB = 192
    /// Set once that early pool exists: a game whose fixed-base exe needs more cannot
    /// load in this run (the pool cannot move without the debugger).
    static var earlyPoolExeWindowMB = 0

    static func jitPreparationValidated() -> Bool {
        guard ideck_process_has_jit_permission() else { return false }
        return ideck_wine_jit_pool_ready() || StikJITHelper.ready
    }

    static let lastLaunchJITKey = "jit.lastLaunchState"

    /// The JIT state at the last launch, kept for bug reports: a report made after a
    /// crash runs in a new process, where CS_DEBUGGED is off again.
    static func recordLaunchJITState() {
        let snapshot = ideck_jit_snapshot()
        let text = "debugged=\(ideck_process_has_jit_permission() ? 1 : 0) debugger=\(snapshot.debugger_attached ? 1 : 0) "
            + "pool=\(ideck_wine_jit_pool_ready() ? 1 : 0) at \(ISOStamp.string(Date()))"
        UserDefaults.standard.set(text, forKey: lastLaunchJITKey)
        AppLog.record("[jit] preparation validated for launch: \(text)")
    }

    /// Runs the pending launch once the debugger is attached, or reports why not.
    private func finishJITRequest(_ result: Result<Void, Error>) {
        refreshJITStatus()
        if let started = jitRequestStartedAt {
            let outcome: String
            switch result {
            case .success: outcome = "debugger attached"
            case .failure(let error): outcome = "failed (" + error.localizedDescription + ")"
            }
            AppLog.record("[jit-handoff] \(outcome) \(String(format: "%.1f", Date().timeIntervalSince(started))) s after the request")
        }
        jitRequestStartedAt = nil
        let generation = pendingJITLaunchGeneration
        let launch = takePendingJITLaunch()
        switch result {
        case .success:
            if wineJITPreparationInFlight {
                pendingJITLaunch = launch
                pendingJITLaunchGeneration = generation
            } else {
                launch?()
            }
        case .failure(let error):
            if launch != nil { setWindowsStatus(error.localizedDescription) }
        }
    }

    private func startWindows() {
        guard !isPreparingWindowsPrefix else { return }
        isPreparingWindowsPrefix = true
        setWindowsStatus("Preparing Windows Environment...")
        prefixHost.mountEnvironment { [weak self] mountPath in
            guard let self else { return }
            guard let mountPath else {
                self.isPreparingWindowsPrefix = false
                self.dockInstallAfterPrefix = false
                self.setWindowsStatus("Windows prefix initialization failed")
                return
            }
            DispatchQueue.main.async {
                self.isContainerReady = true
                guard Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil else {
                    self.isPreparingWindowsPrefix = false
                    self.dockInstallAfterPrefix = false
                    self.setWindowsStatus("Library Ready — Madeira native runtime is not bundled")
                    return
                }
                self.setWindowsStatus("Preparing Wine prefix...")
                self.prefixInstaller.installWinePrefix(to: mountPath) { success in
                    self.isPreparingWindowsPrefix = false
                    guard success else {
                        self.dockInstallAfterPrefix = false
                        self.setWindowsStatus("Wine prefix setup failed")
                        return
                    }
                    self.windowsEnvironment.configureWine(prefix: mountPath)
                    self.mountExternalDrives(prefix: mountPath)
                    let runtimeReady = self.windowsEnvironment.hasRuntime(in: mountPath)
                    self.setWindowsStatus(runtimeReady ? "Windows Runtime Ready" : "Madeira runtime components are missing")
                    if self.dockInstallAfterPrefix {
                        self.dockInstallAfterPrefix = false
                        if runtimeReady { self.installSteamClientComponentsIfNeeded(force: true) }
                        else { self.steamComponentsProgress = "Cannot install Dock: native Wine runtime is incomplete." }
                    }
                }
            }
        }
    }

    static let jitMethodKey = "jit.method"

    /// "builtIn" (iDeck's own helper through LocalDevVPN) or "stikdebug".
    var jitMethod: String {
        UserDefaults.standard.string(forKey: Self.jitMethodKey) ?? "stikdebug"
    }

    /// Enables JIT with iDeck's built-in helper: StikJIT, inside iDeck's own
    /// app extension, attaches to iDeck through LocalDevVPN with the imported
    /// pairing file and runs the bundled universal.js script.
    func requestBuiltInJIT() {
        guard let pairing = try? Data(contentsOf: pairingFileURL), !pairing.isEmpty else {
            builtInFailed("Import a pairing file in Settings › JIT before using the built-in JIT.")
            return
        }
        guard let scriptURL = Bundle.main.url(forResource: "universal", withExtension: "jitscript"),
              let script = try? Data(contentsOf: scriptURL), !script.isEmpty else {
            builtInFailed("Cannot request JIT: the bundled universal.js debugger script is missing.")
            return
        }
        setWindowsStatus("Starting the built-in JIT helper...")
        let request = MadeiraJITRequest.enable(targetPID: getpid(), pairingData: pairing,
                                               scriptBase64: script.base64EncodedString())
        MainActor.assumeIsolated {
            IDeckBuiltInJIT.send(request, started: { [weak self] in
                // The request lasts as long as the debugger stays attached.
                for delay in [1.0, 2.0, 4.0, 8.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refreshJITStatus() }
                }
            }) { [weak self] result in
                guard let self else { return }
                self.refreshJITStatus()
                switch result {
                case .success(let response):
                    AppLog.record("[jit-builtin] finished: \(response.message)")
                    if !response.success { self.builtInFailed("Built-in JIT: " + response.message) }
                case .failure(let error):
                    self.builtInFailed("Built-in JIT: " + error.localizedDescription)
                }
            }
        }
    }

    /// The wait for the debugger that a built-in request started.
    private var builtInWait: Timer?

    /// The helper failed: stop waiting 90 s for a debugger that will not come, and
    /// let the next tap try again at once.
    private func builtInFailed(_ message: String) {
        builtInWait?.invalidate()
        builtInWait = nil
        jitRequestStartedAt = nil
        pendingJITLaunch = nil
        setWindowsStatus(message)
        AppLog.record("[jit-builtin] " + message)
    }

    /// When the JIT request in flight was started (nil: none). A second request
    /// within 20 s joins it instead of opening StikDebug again.
    private var jitRequestStartedAt: Date?
    /// Watches for iDeck coming back in front after StikDebug was opened.
    private var jitHandoffObserver: NSObjectProtocol?

    /// For launches that first need a network round trip (Epic's and EA's launch
    /// tokens): starts JIT activation at once, in parallel with it, so StikDebug
    /// opens on the tap instead of after the store answers. The launch itself still
    /// goes through ensureJITForGameLaunch and waits for the validated preparation.
    func prewarmJITForLaunch() {
        guard Self.restartNeeded() == nil, MadeiraBundleIdentity.isNative,
              StikJITHelper.scriptData != nil, !isClosingWindowsSession else { return }
        refreshJITStatus()
        guard !Self.jitPreparationValidated() else { return }
        setWindowsStatus("JIT is not enabled for this iDeck process. Opening StikDebug...")
        requestStikDebugJIT()
    }

    func requestStikDebugJIT() {
        if let started = jitRequestStartedAt, Date().timeIntervalSince(started) < 20 { return }
        jitRequestStartedAt = Date()
        if jitMethod == "builtIn" {
            // Built-in never falls back to StikDebug silently: the reason it cannot
            // run is shown instead, and the request ends.
            let unavailable = MainActor.assumeIsolated { IDeckBuiltInJIT.unavailableReason }
            if let unavailable {
                jitRequestStartedAt = nil
                setWindowsStatus("Built-in JIT: " + unavailable)
                AppLog.record("[jit-builtin] unavailable: \(unavailable)")
                return
            }
            guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
                jitRequestStartedAt = nil
                setWindowsStatus("Built-in JIT needs this device's pairing file: import it in Settings › JIT.")
                return
            }
            builtInWait?.invalidate()
            builtInWait = StikJITHelper.waitForDebugger { [weak self] result in
                DispatchQueue.main.async { self?.builtInWait = nil; self?.finishJITRequest(result) }
            }
            requestBuiltInJIT()
            return
        }
        // How long the trip to StikDebug and back takes, for bug reports: when iDeck
        // is in front again, and whether the debugger was attached by then.
        let started = Date()
        AppLog.record("[jit-handoff] opening StikDebug")
        if let previous = jitHandoffObserver { NotificationCenter.default.removeObserver(previous) }
        jitHandoffObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            AppLog.record("[jit-handoff] iDeck in front again after \(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
                          + "debugger attached=\(StikJITHelper.ready ? 1 : 0)")
            if let observer = self?.jitHandoffObserver { NotificationCenter.default.removeObserver(observer) }
            self?.jitHandoffObserver = nil
        }
        // Madeira's StikJITHelper.enableJIT, verbatim: stikdebug://enable-jit with
        // the bundle ID, this PID and the script, then a wait for the debugger.
        StikJITHelper.enableJIT { [weak self] result in
            DispatchQueue.main.async { self?.finishJITRequest(result) }
        }
    }

    func disconnectSteamAccount() {
        SteamSignIn.signOut()
        isSteamConnected = false
        currentStatus = "Steam disconnected"
    }

    private var pairingFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pairing_file.mobiledevicepairing")
    }
    
    func refreshPairingFileState() {
        hasPairingFile = FileManager.default.fileExists(atPath: pairingFileURL.path)
    }
    
    /// Imports a pairing file picked with the document picker. Files from the Files app are
    /// security-scoped: without startAccessingSecurityScopedResource the copy silently fails.
    func importPairingFile(at url: URL) {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        
        let fileManager = FileManager.default
        do {
            let data = try Data(contentsOf: url)
            // Pairing files exported by other tools (StikDebug, JitterBug, ...) are accepted as well:
            // a property list or JSON object that carries the usual pairing record keys.
            let knownKeys: Set<String> = ["HostID", "SystemBUID", "UDID", "DeviceCertificate", "HostCertificate",
                                          "HostPrivateKey", "RootCertificate", "RootPrivateKey", "private_key"]
            let object = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                ?? (try? JSONSerialization.jsonObject(with: data))
            guard let record = object as? [String: Any], !knownKeys.isDisjoint(with: record.keys) else {
                currentStatus = "Not a valid pairing file"
                return
            }
            if fileManager.fileExists(atPath: pairingFileURL.path) {
                try fileManager.removeItem(at: pairingFileURL)
            }
            try data.write(to: pairingFileURL, options: [.atomic, .completeFileProtection])
            hasPairingFile = true
            currentStatus = "Pairing file imported"
        } catch {
            currentStatus = "Pairing import failed: \(error.localizedDescription)"
        }
    }
    
    
    /// Holds 120 Hz only while a game runs on screen (ResourceGovernor):
    /// menus, the background and Low Power Mode keep the system's rate.
    private func applyMaxRefreshRate() {
        let wanted = isMaxRefreshRateEnabled && MainActor.assumeIsolated { ResourceGovernor.maxRateAllowed }
        guard wanted != (displayLink != nil) else { return }
        if wanted {
            displayLink = CADisplayLink(target: self, selector: #selector(dummyDisplayLinkUpdate))
            if #available(iOS 15.0, *) {
                var maxFPS: Float = 60.0
                let scenes = UIApplication.shared.connectedScenes
                if let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                    maxFPS = Float(windowScene.screen.maximumFramesPerSecond)
                }
                displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: maxFPS, maximum: maxFPS, preferred: maxFPS)
            }
            displayLink?.add(to: .main, forMode: .common)
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
    
    @objc private func dummyDisplayLinkUpdate() {}
    
    func launchSteam() {
        guard !isClosingWindowsSession else { return }
        guard !previousWineSessionStillFinishing() else { return }
        currentSteamLaunchUsesDock = false
        dockLaunchAccepted = false
        steamDockLaunchStage = nil
        guard MadeiraBundleIdentity.isNative else {
            setWindowsStatus(MadeiraBundleIdentity.missingRuntimeMessage)
            return
        }
        guard isContainerReady else { return }
        guard ensureJITForGameLaunch() else { return }

        setWindowsStatus("Downloading Steam...")
        prefixHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            guard let mountPath = mountPath else {
                self.setWindowsStatus("Container not initialized")
                return
            }
            guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                DispatchQueue.main.async {
                    self.setWindowsStatus("Madeira runtime missing: in-process FEX, Wine ARM64EC, DXMT, D3D12 and native launch bridge are not linked.")
                }
                return
            }
            guard self.windowsEnvironment.hasWoW64Runtime() else {
                self.setWindowsStatus("Cannot install the Windows Steam client: this IPA does not contain a verified WoW64 runtime. Rebuild the Madeira-native IPA with WoW64 enabled (the default).")
                return
            }
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.mountExternalDrives(prefix: mountPath)
            let steamProfile = WindowsGameProfile(id: "steam", title: "Steam")
            self.activeWindowsProfile = steamProfile
            self.windowsEnvironment.applyGameProfile(steamProfile)
            self.setWindowsStatus("Launching Steam client...")
            self.withPreparedMetalDisplay(expectedStatus: "Launching Steam client...") { [weak self] in
                guard let self else { return }
                self.windowsEnvironment.installAndRunSteam(jitEnabler: self.jitEnabler) { result in
                    DispatchQueue.main.async {
                        guard self.windowsStatus == "Launching Steam client..." else { return }
                        // The Windows Steam loader may report success before
                        // the Steam window draws a single Metal frame. Use the
                        // same first-frame gate as Steam games and direct EXEs.
                        let loaderAlive = result && ideck_wineprocess_running()
                        if loaderAlive {
                            SteamLog.event("[steam-start] Steam client Wine thread started; awaiting Metal first frame")
                        }
                        self.setWindowsStatus(loaderAlive
                            ? "Wine started; waiting for game..." : "Execution Error: Windows Steam client failed to start.")
                    }
                }
            }
        }
    }
    
    private func withPreparedMetalDisplay(expectedStatus: String, remainingChecks: Int = 300, perform: @escaping () -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.withPreparedMetalDisplay(expectedStatus: expectedStatus, remainingChecks: remainingChecks, perform: perform)
            }
            return
        }
        guard windowsStatus == expectedStatus else { return }
        guard WindowsRendererView.isNativeDisplayLinked else {
            pendingSteamGameID = nil
            setWindowsStatus("Execution Error: this IPA has no linked Madeira Metal display backend. Install a Madeira-native build, not an interface-only IPA.")
            return
        }
        if WindowsRendererView.isReadyForFrames {
            perform()
            return
        }
        guard remainingChecks > 0 else {
            pendingSteamGameID = nil
            setWindowsStatus("Execution Error: Metal display surface did not become ready. Wine was not started.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.withPreparedMetalDisplay(expectedStatus: expectedStatus,
                                           remainingChecks: remainingChecks - 1,
                                           perform: perform)
        }
    }

    func approveVisualCRuntimeInstallation() {
        guard let action = visualCRuntimeConsentAction else { return }
        needsVisualCRuntimeConsent = false
        visualCRuntimeConsentAction = nil
        visualCRuntimeSkipAction = nil
        UserDefaults.standard.set(true, forKey: "ideckInstallOfficialVisualCRedist")
        action()
    }

    func skipVisualCRuntimeInstallation() {
        let action = visualCRuntimeSkipAction
        guard action != nil else { return }
        needsVisualCRuntimeConsent = false
        visualCRuntimeConsentAction = nil
        visualCRuntimeSkipAction = nil
        action?()
    }

    /// Programs whose dependencies were already offered this run (a failed download
    /// does not block every launch).
    private var onDemandAttempted = Set<String>()
    private var bundledRuntimeChecked = false
    /// Program path -> size and modification date when its libraries were complete.
    private var satisfiedExecutables: [String: String] = [:]

    private static func fileStamp(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return "\(values.fileSize ?? -1)@\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
    }
    private var onDemandInstallTask: Task<Void, Never>?

    /// On demand, before Wine starts: the Visual C++ runtime (by version and
    /// architecture) and .NET support (Wine Mono) that `executable` imports, and
    /// nothing else. Returns true when it installs and calls `resume` afterwards.
    private func prepareVisualCRuntimeIfNeeded(prefix: URL, executable: URL?, resume: @escaping () -> Void) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                _ = self?.prepareVisualCRuntimeIfNeeded(prefix: prefix, executable: executable, resume: resume)
            }
            return true
        }
        if onDemandInstallTask != nil { return true }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        // Visual C++ built into a development app: in place without installing anything
        // (checked once per run: the marker does not change while iDeck runs).
        if !bundledRuntimeChecked, let documents {
            bundledRuntimeChecked = VisualCRuntimeBootstrap.installBundled(documents: documents)
                || !VisualCRuntimeBootstrap.bundled
        }
        guard let executable else { return false }
        lastPreparedExecutable = executable
        // A program already found complete in this run, unchanged since, is not read
        // and checked again (PE imports, Visual C++, Mono, D3DX lookups).
        let stamp = Self.fileStamp(executable)
        if let stamp, satisfiedExecutables[executable.path] == stamp { return false }
        guard let pe = WindowsPEInfo.read(executable),
              !onDemandAttempted.contains(executable.path) else { return false }
        let needed = MainActor.assumeIsolated { WindowsInstallerEnvironment.missing(WindowsRequirements.of(pe)) }
        let d3dx = NativeD3DX.wanted(executable) && !NativeD3DX.installed(for: executable)
        guard !needed.isEmpty || d3dx else {
            if let stamp { satisfiedExecutables[executable.path] = stamp }
            return false
        }
        onDemandAttempted.insert(executable.path)
        AppLog.record("[installer] \(executable.lastPathComponent) needs \(needed)\(d3dx ? " and Microsoft's D3DX 9" : "")")
        onDemandInstallTask = Task { @MainActor [weak self] in
            var failures: [String] = []
            if !needed.isEmpty {
                failures = await WindowsInstallerEnvironment.install(needed) { [weak self] message in
                    self?.setWindowsStatus(message)
                }
            }
            if d3dx {
                self?.setWindowsStatus("Installing Microsoft D3DX 9 and its shader compiler (about 95 MB, once)…")
                do { try await NativeD3DX.provide(for: executable, machine: pe.machine, prefix: prefix) }
                catch {
                    AppLog.record("[d3dx] not provided: \(error.localizedDescription)")
                    failures.append("Microsoft D3DX 9: \(error.localizedDescription)")
                }
            }
            self?.onDemandInstallTask = nil
            if !failures.isEmpty { self?.setWindowsStatus(failures.joined(separator: "\n")) }
            resume()
        }
        return true
    }


    enum StoreClient: String, CaseIterable {
        case ubisoft = "Ubisoft Connect", ea = "EA app"

        static func required(for publishers: [String], title: String) -> Self? {
            for publisher in publishers {
                let name = publisher.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("ubisoft") || name == "uplay" { return .ubisoft }
                if name.hasPrefix("electronic arts") || ["ea", "ea sports", "ea originals", "origin"].contains(name) {
                    let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
                    return words.prefix(2).elementsEqual(["battlefield", "6"]) ? nil : .ea
                }
            }
            return nil
        }

        var installInstruction: String {
            tr("Install it in Settings › Stores & launchers › %@.", rawValue)
        }

        static var drive: URL { MadeiraDock.prefix.appendingPathComponent("drive_c") }

        var installedURL: URL? { installedURL(prefix: MadeiraDock.prefix) }

        /// The launcher in `prefix`, or nil when it is not installed there.
        func installedURL(prefix: URL) -> URL? {
            let drive = prefix.appendingPathComponent("drive_c")
            var folders: [String] = []
            let names: [String]
            switch self {
            case .ubisoft:
                // Where the installer put it (its own registry value), then both Program
                // Files folders: a 64-bit installer does not use Program Files (x86), so
                // checking that folder alone missed an installed launcher.
                if let dir = Self.registryValue(key: "Software\\Wow6432Node\\Ubisoft\\Launcher", name: "InstallDir", prefix: prefix)
                    ?? Self.registryValue(key: "Software\\Ubisoft\\Launcher", name: "InstallDir", prefix: prefix) {
                    folders.append(dir)
                }
                folders += ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher", "Program Files/Ubisoft/Ubisoft Game Launcher"]
                names = ["UbisoftConnect.exe", "upc.exe"]
            case .ea:
                folders = ["Program Files/Electronic Arts/EA Desktop/EA Desktop", "Program Files (x86)/Electronic Arts/EA Desktop/EA Desktop"]
                names = ["EADesktop.exe"]
            }
            for folder in folders {
                for name in names {
                    let url = drive.appendingPathComponent(folder).appendingPathComponent(name)
                    if VisualCRuntimeBootstrap.hasPE(url, machines: [0x014c, 0x8664, 0xaa64]) { return url }
                }
            }
            return nil
        }

        /// A C:\ path value from the prefix's system.reg, as a drive-relative path.
        static func registryValue(key: String, name: String, prefix: URL = MadeiraDock.prefix) -> String? {
            let file = prefix.appendingPathComponent("system.reg")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            // Wine's .reg files write each backslash of a key name twice.
            let header = "[" + key.lowercased().replacingOccurrences(of: "\\", with: "\\\\") + "]"
            var inside = false
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let end = text.utf8[cursor...].firstIndex(of: 10) ?? text.endIndex
                let line = text.utf8[cursor..<end]
                cursor = end == text.endIndex ? end : text.utf8.index(after: end)
                let l = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if l.hasPrefix("[") { inside = l.lowercased().hasPrefix(header); continue }
                guard inside, l.lowercased().hasPrefix("\"" + name.lowercased() + "\"=\"") else { continue }
                var value = String(l.dropFirst(name.count + 4).dropLast())
                value = value.replacingOccurrences(of: "\\\\", with: "/")
                guard value.lowercased().hasPrefix("c:/") else { return nil }
                return String(value.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return nil
        }

        /// The official installer, downloaded when the user taps Install (not in the IPA).
        var downloadURL: URL {
            switch self {
            case .ubisoft: return URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
            case .ea: return URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!
            }
        }

        var installerName: String { downloadURL.lastPathComponent }

        struct InstallError: Error { let reason: String }

        /// Where the launcher's files go, relative to drive_c.
        var installFolder: String {
            switch self {
            case .ubisoft: return "Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
            case .ea: return "Program Files/Electronic Arts/EA Desktop"
            }
        }

        /// Downloads the official installer and copies the launcher's files into the
        /// prefix, as its installer would: Ubisoft Connect's NSIS installer is opened
        /// on the device; the EA app's installer only names the Windows Installer
        /// package it downloads, which is downloaded and opened instead.
        static func installWithoutWine(_ client: StoreClient, progress: @escaping @MainActor (String) -> Void) async throws {
            let fm = FileManager.default
            let drive = Self.drive
            let folder = drive.appendingPathComponent("iDeck", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if client.installer == nil {
                await progress(tr("Downloading %@ installer...", client.rawValue))
                try await download(client.downloadURL, to: folder.appendingPathComponent(client.installerName))
            }
            guard let installer = client.installer else {
                throw InstallError(reason: tr("The installer is missing or invalid."))
            }
            var archive = installer
            if client == .ea {
                let manifest = folder.appendingPathComponent("EAappInstaller-manifest.xml")
                defer { try? fm.removeItem(at: manifest) }
                try await Task.detached(priority: .userInitiated) {
                    try check { ideck_burn_manifest(installer.path, manifest.path, $0, $1) }
                }.value
                guard let package = packageURL(manifest: (try? String(contentsOf: manifest, encoding: .utf8)) ?? "") else {
                    throw InstallError(reason: tr("The installer does not name the EA app's package."))
                }
                archive = folder.appendingPathComponent(package.lastPathComponent)
                if !fm.fileExists(atPath: archive.path) {
                    await progress(tr("Downloading %@...", client.rawValue))
                    try await download(package, to: archive)
                }
            }
            await progress(tr("Installing %@...", client.rawValue))
            // Extracted next to drive_c (same volume), then moved into place.
            let staging = folder.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let target = client == .ubisoft ? staging.appendingPathComponent(client.installFolder, isDirectory: true) : staging
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let source = archive
            try await Task.detached(priority: .userInitiated) {
                if client == .ubisoft {
                    try check { ideck_nsis_extract(source.path, target.path, $0, $1) }
                } else {
                    try check { ideck_msi_extract(source.path, target.path, $0, $1) }
                }
            }.value
            try await Task.detached(priority: .userInitiated) { try merge(staging, into: drive) }.value
            if client == .ea { try? fm.removeItem(at: archive) }
            guard client.installedURL != nil else {
                throw InstallError(reason: tr("The launcher's files were copied, but its program is missing."))
            }
            writeRegistry(client)
        }

        /// Runs an extractor call with an error buffer; a negative result throws its reason.
        private static func check(_ call: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
            var message = [CChar](repeating: 0, count: 512)
            let result = message.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
            if result < 0 { throw InstallError(reason: tr(String(cString: message))) }
        }

        /// The Windows Installer package a Burn manifest downloads, on EA's own server only.
        static func packageURL(manifest: String) -> URL? {
            guard let range = manifest.range(of: #"DownloadUrl="https://[^"]+\.msi""#, options: .regularExpression) else { return nil }
            let value = manifest[range].dropFirst("DownloadUrl=\"".count).dropLast()
            guard let url = URL(string: String(value)), url.scheme == "https",
                  url.host == "origin-a.akamaihd.net", url.path.hasPrefix("/EA-Desktop-Client-Download/") else { return nil }
            return url
        }

        private static func download(_ url: URL, to target: URL) async throws {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileReadUnknown)
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        }

        /// Moves every file of `staging` to the same place under `drive`, replacing
        /// an older copy (a launcher reinstalled over itself).
        static func merge(_ staging: URL, into drive: URL) throws {
            let fm = FileManager.default
            let base = staging.standardizedFileURL.path + "/"
            guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            for case let file as URL in walker {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
                guard !relative.isEmpty, !relative.hasPrefix(".") else { continue }
                let destination = drive.appendingPathComponent(relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: file, to: destination)
            }
        }

        /// The registry values the installer would write: the install folder (read by
        /// games and by installedURL), and the EA app's background service.
        static func writeRegistry(_ client: StoreClient, prefix: URL = MadeiraDock.prefix) {
            guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
            let windowsFolder = "C:\\" + client.installFolder.replacingOccurrences(of: "/", with: "\\")
            var values: [SteamInstallValue]
            switch client {
            case .ubisoft:
                values = ["Software\\Wow6432Node\\Ubisoft\\Launcher", "Software\\Ubisoft\\Launcher"].map {
                    SteamInstallValue(hive: .machine, key: $0, name: "InstallDir", data: .string(windowsFolder + "\\"), followsInstall: true)
                }
            case .ea:
                let service = "System\\CurrentControlSet\\Services\\EABackgroundService"
                let program = windowsFolder + "\\EA Desktop\\EABackgroundService.exe"
                values = [
                    SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallLocation",
                                      data: .string(windowsFolder), followsInstall: true),
                    SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallSuccessful",
                                      data: .string("true"), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "Type", data: .dword(0x110), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "Start", data: .dword(3), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "ErrorControl", data: .dword(1), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "ImagePath",
                                      data: .string("\"" + program + "\" -start"), followsInstall: true),
                    SteamInstallValue(hive: .machine, key: service, name: "DisplayName",
                                      data: .string("EABackgroundService"), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "ObjectName",
                                      data: .string("LocalSystem"), followsInstall: false),
                ]
            }
            do {
                let changed = try EARegistry.write(values, prefix: prefix)
                AppLog.record("[store-setup] \(client.rawValue): \(changed) registry line(s) written")
            } catch {
                AppLog.record("[store-setup] \(client.rawValue): registry not written: \(error.localizedDescription)")
            }
        }

        /// The programs of the EA app and Ubisoft Connect that check which Windows
        /// they run on: the EA app needs Windows 10 or later and refused to install
        /// on an older version. Written while no session runs (the registry is on disk).
        static let windows10Programs = ["EAappInstaller.exe", "EADesktop.exe", "EABackgroundService.exe",
                                        "EALauncher.exe", "EALocalHostSvc.exe", "EACrashReporter.exe",
                                        "UbisoftConnectInstaller.exe", "UbisoftConnect.exe", "upc.exe", "UplayService.exe"]

        static func prepareInstallEnvironment(prefix: URL = MadeiraDock.prefix) {
            guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
                AppLog.record("[store-setup] Windows version not set: a Windows session is still running")
                return
            }
            let values = windows10Programs.map {
                SteamInstallValue(hive: .user, key: "Software\\Wine\\AppDefaults\\" + $0, name: "Version",
                                  data: .string("win10"), followsInstall: true)
            }
            do {
                let changed = try EARegistry.write(values, prefix: prefix)
                // The installers write under %TEMP%: make sure the profile's folder exists.
                if let user = SteamCloudPaths.userFolder(drive: prefix.appendingPathComponent("drive_c"))?.url {
                    try? FileManager.default.createDirectory(at: user.appendingPathComponent("AppData/Local/Temp"),
                                                             withIntermediateDirectories: true)
                }
                AppLog.record("[store-setup] Windows 10 reported to the EA app and Ubisoft Connect (\(changed) registry line(s) changed)")
            } catch {
                AppLog.record("[store-setup] Windows version not set: \(error.localizedDescription)")
            }
        }

        /// The launcher an executable is (EA app, Ubisoft Connect), or nil for any other program.
        static func displayName(for executable: URL) -> String? {
            switch executable.lastPathComponent.lowercased() {
            case "ubisoftconnect.exe", "upc.exe": return Self.ubisoft.rawValue
            case "eadesktop.exe": return Self.ea.rawValue
            default: return nil
            }
        }

        /// The downloaded installer in C:\iDeck, when present.
        var installer: URL? {
            let url = Self.drive.appendingPathComponent("iDeck/" + installerName)
            return VisualCRuntimeBootstrap.hasPE(url, machines: [0x014c, 0x8664, 0xaa64]) ? url : nil
        }
    }

    /// The store client whose installer is downloading, and its progress text.
    @Published private(set) var storeClientDownload: String?

    /// The EA app and Ubisoft Connect are installing (downloaded and copied on the device, without Wine).
    @Published private(set) var storeSetupInBackground = false
    /// Why the last background installation of the launchers failed.
    @Published private(set) var storeClientError: String?

    /// Installs the launcher when it is missing. An installed launcher is not opened from
    /// iDeck: its games are on its store page.
    func openStoreClient(_ client: StoreClient) {
        guard client.installedURL == nil else { return }
        installDefaultStoreClients([client])
    }

    /// Installs the EA app and Ubisoft Connect without Wine or JIT: each official
    /// installer is downloaded and opened on the device (LauncherArchiveExtractor),
    /// its files are copied into the prefix and its registry values written. No
    /// Windows program runs, so nothing waits for StikDebug or a Metal surface.
    func installDefaultStoreClients(_ clients: [StoreClient] = StoreClient.allCases) {
        guard !isClosingWindowsSession, !ideck_wineprocess_running(), storeClientDownload == nil,
              !storeSetupInBackground else { return }
        let missing = clients.filter { $0.installedURL == nil }
        guard !missing.isEmpty else { return }
        storeSetupInBackground = true
        storeClientError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.storeClientDownload = nil
                self.storeSetupInBackground = false
            }
            for client in missing {
                do {
                    try await StoreClient.installWithoutWine(client) { [weak self] text in
                        self?.storeClientDownload = text
                    }
                    AppLog.record("[store-setup] \(client.rawValue) installed without Wine")
                } catch {
                    let reason = (error as? StoreClient.InstallError)?.reason
                        ?? tr("Could not download the installer. Check the connection and try again.")
                    AppLog.record("[store-setup] \(client.rawValue) not installed: \(reason)")
                    self.storeClientError = "Execution Error: " + client.rawValue + ": " + reason
                    return
                }
            }
            StoreClient.prepareInstallEnvironment()
        }
    }

    /// Starts any Windows program or installer through the universal installer
    /// environment: installs the Visual C++ runtime or .NET support it imports, picks
    /// the installer technology's switches (an .msi runs through msiexec), then starts it.
    /// Store games pass `detectInstaller: false`: only their dependencies are handled.
    func launchWindowsProgram(at url: URL, profile: WindowsGameProfile? = nil, silent: Bool = false,
                              detectInstaller: Bool = true) {
        let prefix = MadeiraDock.prefix
        guard let plan = WindowsInstallerEnvironment.plan(for: url, prefix: prefix, silent: silent,
                                                          detectInstaller: detectInstaller) else {
            launchWindowsExecutable(at: url, profile: profile)
            return
        }
        if let kind = plan.kind { AppLog.record("[installer] \(url.lastPathComponent): \(kind.rawValue)") }
        // An .msi starts through msiexec: remember the installer itself, so it leaves
        // the list once what it installed is there.
        if plan.kind != nil { WindowsLibraryStore.noteLaunch(of: url) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !WindowsInstallerEnvironment.missing(plan.requirements).isEmpty {
                let failures = await WindowsInstallerEnvironment.install(plan.requirements) { [weak self] message in
                    self?.setWindowsStatus(message)
                }
                if !failures.isEmpty { self.setWindowsStatus(failures.joined(separator: "\n")) }
            }
            var launch = profile ?? WindowsGameProfile(id: "windows:" + url.lastPathComponent.lowercased(),
                                                       title: url.deletingPathExtension().lastPathComponent)
            // The profile's own arguments win; the technology's switches come first.
            if plan.kind != nil {
                launch.arguments = [plan.arguments, launch.arguments].filter { !$0.isEmpty }.joined(separator: " ")
            }
            // Installers draw GDI dialogs on the Windows desktop: touches map onto the
            // whole desktop picture, not a game window's client area.
            self.nextLaunchIsInstaller = plan.kind != nil
            self.launchWindowsExecutable(at: plan.executable, profile: launch)
        }
    }

    /// When the current Windows session started (EA games closing by themselves).
    private var sessionStartedAt: Date?
    /// When a Steam game was last started without Steam's client (SteamClientNeed).
    private var directSteamStartedAt: Date?

    /// Why an EA app game closed by itself, from its part of the Wine log, or nil
    /// for a session that ran long enough to be a normal quit with nothing in the log.
    static func eaFailureReason(logURL: URL?, since offset: Int64?, seconds: TimeInterval) -> String? {
        func has(_ needles: [String]) -> Bool { sessionLogContains(needles, logURL: logURL, since: offset) }
        let prefix = "Execution Error: EA app game closed. "
        if has(["activationui.exe"]) {
            return prefix + "EA's licence was refused (the game opened EA's activation window). iDeck asks for the licence another way at the next launch: start the game again."
        }
        if has(["eaanticheat", "easyanticheat", "eac_launcher", "anticheat.x64"]) {
            return prefix + "The game requires EA's anti-cheat, which cannot run under Wine on iOS."
        }
        if has(["license not found", "licence not found", "no license", "invalid license", "license expired", "ownership check failed"]) {
            return prefix + "EA's licence for this game could not be read. Sign in to the EA app again in Settings › Stores and launchers, then start the game again."
        }
        if has(["eadesktop.exe", "eabackgroundservice", "origin.exe", "ealauncher", "link2ea"]) {
            return prefix + "The game asked for the EA app client, which iDeck does not run. Start it from iDeck's EA app library, not from its own launcher."
        }
        if has(["c0000135", "could not load", "library not found", "not found in the dll"]) {
            return prefix + "A Windows DLL the game needs is missing. Copy the bug report from Bugs & logs to see which one."
        }
        guard seconds < 120 else { return nil }
        return prefix + "It stopped \(Int(seconds)) s after starting without an error from Windows. Copy the bug report from Bugs & logs for the details."
    }

    /// Set by launchWindowsProgram right before an installer starts; read once.
    private var nextLaunchIsInstaller = false

    func launchWindowsExecutable(at url: URL, profile: WindowsGameProfile? = nil, installer: Bool = false) {
        let installerSession = installer || nextLaunchIsInstaller
            || url.pathExtension.lowercased() == "msi"
            || WindowsRendererView.looksLikeInstaller(url.lastPathComponent)
        WindowsRendererView.installerTouchMapping = installerSession
        nextLaunchIsInstaller = false
        sessionStartedAt = Date()
        guard !isClosingWindowsSession else { return }
        guard !previousWineSessionStillFinishing() else { return }
        if let id = profile?.id, let held = MemoryGuard.holdMessage(id) {
            setWindowsStatus(held)
            return
        }
        isSteamSession = false
        let gameID = profile?.id ?? ""
        // The EA app's environment (EALibrary.prepareLaunch) belongs to EA games only.
        if !gameID.hasPrefix("ea:") { EALibrary.clearEnvironment() }
        // The Galaxy service belongs to the GOG game it was prepared for.
        if !gameID.hasPrefix("gog:") { DispatchQueue.main.async { MainActor.assumeIsolated { GOGGalaxy.shared.stop() } } }
        let launcher = gameID.hasPrefix("epic:") ? "Epic Games" : gameID.hasPrefix("ea:") ? "EA app"
            : gameID.hasPrefix("gog:") || gameID.hasPrefix("gog-setup:") ? "GOG" : ".exe"
        recordGameContext(profile?.title ?? url.deletingPathExtension().lastPathComponent, launcher: launcher)
        if launcher == ".exe" { WindowsLibraryStore.noteLaunch(of: url) }
        BenchmarkSession.begin(kind: "game", scenario: profile?.title ?? url.deletingPathExtension().lastPathComponent,
                               settings: BenchmarkSession.gameSettings(profile))
        currentSteamLaunchUsesDock = false
        dockLaunchAccepted = false
        steamDockLaunchStage = nil
        guard MadeiraBundleIdentity.isNative else {
            setWindowsStatus(MadeiraBundleIdentity.missingRuntimeMessage)
            return
        }
        guard isContainerReady else { return }
        refreshJITStatus()

        guard url.pathExtension.lowercased() == "exe" else {
            setWindowsStatus("Choose a Windows .exe executable.")
            return
        }

        setWindowsStatus("Preparing executable...")
        let fileManager = FileManager.default
        let hasScope = url.startAccessingSecurityScopedResource()

        prefixHost.mountEnvironment { [weak self] mountPath in
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            guard let mountPath else {
                self.setWindowsStatus("Container initialization failed")
                return
            }

            do {
                let root = URL(fileURLWithPath: mountPath, isDirectory: true)
                let downloads = root.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
                try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)

                let source = url.standardizedFileURL
                let downloadDirectory = downloads.standardizedFileURL
                // A program already inside the prefix (an installed GOG or Epic
                // game, or anything under C:\) starts in place, next to its DLLs.
                let drive = root.appendingPathComponent("drive_c", isDirectory: true).standardizedFileURL
                let insidePrefix = source.path.hasPrefix(drive.path + "/") ||
                    source.resolvingSymlinksInPath().path.hasPrefix(drive.resolvingSymlinksInPath().path + "/")
                let isAlreadyInLibrary = source.deletingLastPathComponent() == downloadDirectory || insidePrefix
                let destination: URL

                if isAlreadyInLibrary {
                    guard fileManager.fileExists(atPath: source.path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    destination = source
                } else {
                    var candidate = downloads.appendingPathComponent(url.lastPathComponent)
                    if fileManager.fileExists(atPath: candidate.path) {
                        let stem = candidate.deletingPathExtension().lastPathComponent
                        candidate = downloads.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).exe")
                    }
                    try fileManager.copyItem(at: url, to: candidate)
                    destination = candidate
                }

                let launchPrepared: () -> Void = { [weak self] in
                    guard let self else { return }
                    guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                        let missing = self.windowsEnvironment.missingRuntimeComponents(in: mountPath)
                        self.setWindowsStatus("Madeira runtime missing: " + missing.joined(separator: ", "))
                        return
                    }
                    let prefix = URL(fileURLWithPath: mountPath, isDirectory: true)
                    if self.prepareVisualCRuntimeIfNeeded(prefix: prefix, executable: destination, resume: { [weak self] in
                        self?.launchWindowsExecutable(at: destination, profile: profile, installer: installerSession)
                    }) { return }
                    self.jitResume = { [weak self] in self?.launchWindowsExecutable(at: destination, profile: profile, installer: installerSession) }
                    guard self.ensureJITForGameLaunch() else { return }
                    self.windowsEnvironment.configureWine(prefix: mountPath)
                    self.mountExternalDrives(prefix: mountPath)
                    let effectiveProfile = profile ?? WindowsGameProfile(id: destination.path, title: destination.deletingPathExtension().lastPathComponent)
                    self.windowsEnvironment.applyGameProfile(effectiveProfile)
                    // Store installers: Wine's services.exe never answered its RPC clients
                    // under madsync, so the service manager and msiexec's custom actions
                    // waited. That session uses Wine's standard synchronization.
                    if effectiveProfile.id.hasPrefix("ideck:store-") { setenv("MADEIRA_MADSYNC_SESSION", "0", 1) }
                    self.activeWindowsProfile = effectiveProfile
                    self.setWindowsStatus("Launching Windows app...")
                    self.withPreparedMetalDisplay(expectedStatus: "Launching Windows app...") { [weak self] in
                        guard let self else { return }
                        guard !ideck_wineprocess_running() else {
                            self.setWindowsStatus("Execution Error: another Wine process is already running.")
                            return
                        }
                        self.captureWineLogStart()
                        self.windowsEnvironment.execute(
                            binary: destination,
                            arguments: profile?.arguments ?? "",
                            // GOG offline installers can be PE32 even when
                            // the installed game itself is x64. Route by the
                            // verified PE machine, not by filename or store.
                            is32Bit: WindowsEnvironment.isPE32WindowsExecutable(destination),
                            isSteam: false,
                            jitEnabler: self.jitEnabler
                        ) { [weak self] result in
                            DispatchQueue.main.async {
                                guard let self, self.windowsStatus == "Launching Windows app..." else { return }
                                // A live Wine loader thread is not a rendered
                                // Windows game. Wait for a real Metal present
                                // before the game UI reports Running.
                                self.setWindowsStatus(result == 0 && ideck_wineprocess_running()
                                    ? "Wine started; waiting for game..." : self.nativeLaunchFailure(result))
                            }
                        }
                    }
                }

                let prefixURL = URL(fileURLWithPath: mountPath, isDirectory: true)
                if !PrefixInstaller.isPrefixInstalled(at: prefixURL) &&
                    Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil {
                    self.setWindowsStatus("Preparing Wine prefix...")
                    self.prefixInstaller.installWinePrefix(to: mountPath) { [weak self] success in
                        if success {
                            launchPrepared()
                        } else {
                            self?.setWindowsStatus("Wine prefix setup failed")
                        }
                    }
                } else {
                    launchPrepared()
                }
            } catch {
                self.setWindowsStatus("Executable import failed: \(error.localizedDescription)")
            }
        }
    }

    /// Launches a Steam game in its original installation directory, preserving
    /// relative DLL and asset paths instead of copying the executable elsewhere.
    /// Steam games that need no Steam client to run and fail when Valve's
    /// client spawns them: Bully: Scholarship Edition (12200) is a 32-bit
    /// program, and as a child of the 64-bit Steam client its i386 process
    /// started without an emulator CPU area (x28 = 0) and stopped at its first
    /// instruction (0xC000001D). Started directly, it is the session's own
    /// WoW64 process, set up like any other 32-bit game.
    static let directSteamLaunchAppIDs: Set<UInt32> = [12200]

    func launchSteamGame(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL, skipSteamClient: Bool = false) {
        // A game that asked for Steam's client when started without it (SteamClientNeed)
        // goes through Madeira Dock, even when it is on the direct list.
        let needsClient = SteamClientNeed.needs(game.appID)
        let skipSteamClient = !needsClient && (skipSteamClient || Self.directSteamLaunchAppIDs.contains(game.appID))
        guard !isClosingWindowsSession else { return }
        if let held = MemoryGuard.holdMessage("steam:\(game.appID)") {
            setWindowsStatus(held)
            return
        }
        isSteamSession = true
        recordGameContext(game.name, launcher: "Steam")
        var benchmarkSettings = BenchmarkSession.gameSettings(profile)
        benchmarkSettings["store"] = "steam"
        BenchmarkSession.begin(kind: "game", scenario: game.name, settings: benchmarkSettings)
        guard MadeiraBundleIdentity.isNative else {
            setWindowsStatus(MadeiraBundleIdentity.missingRuntimeMessage)
            return
        }
        refreshJITStatus()
        if let pendingSteamGameID {
            setWindowsStatus(pendingSteamGameID == game.appID
                ? "Launching Steam game..."
                : "Cannot launch: a different Steam game is already starting.")
            return
        }
        let standardizedPrefix = prefixPath.standardizedFileURL.path
        if ideck_wineprocess_running() {
            guard activeSteamGameID == game.appID, activeSteamPrefix == standardizedPrefix else {
                setWindowsStatus("Cannot launch: Wine is already running a different or unverified session. Exit that Wine session before launching this game.")
                return
            }
            // A duplicate launch request is not a new Metal present.
            // Preserve actual first-frame readiness instead of replacing
            // "waiting for game" with a false-positive Running state.
            if windowsStatus != "Running" {
                setWindowsStatus("Wine started; waiting for game...")
            }
            return
        }
        guard !previousWineSessionStillFinishing() else { return }
        activeSteamGameID = nil
        activeSteamPrefix = nil

        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        guard SteamInstallFiles.buildID(appID: Int(game.appID), steamApps: steamApps) != nil else {
            setWindowsStatus("Cannot launch: this Steam game is not installed.")
            return
        }

        let folderName = SteamInstallFiles.installDirectoryName(
            appID: Int(game.appID), steamApps: steamApps) ??
            SteamInstallFiles.safeFolderName(
                game.installDir.isEmpty ? "app_\(game.appID)" : game.installDir)
        let directory = SteamInstallPaths.common(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
            .appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            setWindowsStatus("Cannot launch: the installed game folder is missing.")
            return
        }
        guard let selected = steamExecutable(game: game, directory: directory) else {
            setWindowsStatus("Cannot launch: no Windows .exe was found in this game's installed files.")
            return
        }
        let executableURL = selected.url
        let entryArguments = selected.arguments
        SteamLog.event("[steam-start] app=\(game.appID) exe=\(executableURL.lastPathComponent) cwd=\(selected.workingDirectory.lastPathComponent) source=\(selected.source)")
        if !PrefixInstaller.isPrefixInstalled(at: prefixPath) &&
            Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil {
            setWindowsStatus("Preparing Wine prefix...")
            prefixInstaller.installWinePrefix(to: prefixPath.path) { [weak self] success in
                guard let self else { return }
                if success {
                    self.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath)
                } else {
                    self.setWindowsStatus("Wine prefix setup failed")
                }
            }
            return
        }
        guard windowsEnvironment.hasRuntime(in: prefixPath.path) else {
            let missing = windowsEnvironment.missingRuntimeComponents(in: prefixPath.path)
            setWindowsStatus("Madeira runtime missing: " + missing.joined(separator: ", ") +
                             ". Compile and link the native runtime into the iDeck IPA.")
            return
        }

        // Downloads first (Visual C++, Steam's client components), JIT last: the
        // debugger must be attached only for the launch itself. A StikDebug
        // session that ends during a long download takes iDeck down with it.
        if prepareVisualCRuntimeIfNeeded(prefix: prefixPath, executable: executableURL, resume: { [weak self] in
            self?.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath, skipSteamClient: skipSteamClient)
        }) { return }
        if !skipSteamClient && MadeiraDock.bundled && !MadeiraDock.clientInstalled {
            installSteamComponentsThenLaunch(game: game, profile: profile, prefixPath: prefixPath)
            return
        }
        jitResume = { [weak self] in
            self?.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath, skipSteamClient: skipSteamClient)
        }
        guard ensureJITForGameLaunch() else { return }
        windowsEnvironment.configureWine(prefix: prefixPath.path)
        mountExternalDrives(prefix: prefixPath.path)
        windowsEnvironment.graphicsConfig.applyGraphicsEnvironment()
        let effectiveProfile = profile
        windowsEnvironment.applyGameProfile(effectiveProfile)
        activeWindowsProfile = effectiveProfile
        // Steam games start through Valve's client (Madeira Dock) on their
        // own whenever its components are installed and supported; the
        // components install automatically when the Steam account signs in.
        if !skipSteamClient {
            guard MadeiraDock.bundled else {
                setWindowsStatus("Cannot launch: Madeira Dock is not included in this IPA. Use an explicit direct launch only for games that do not require Steam.")
                return
            }
            if MadeiraDock.clientInstalled && MadeiraDock.clientSupported {
                launchThroughDock(game: game, profile: profile, prefixPath: prefixPath)
                return
            }
            if !MadeiraDock.clientInstalled {
                installSteamComponentsThenLaunch(game: game, profile: profile, prefixPath: prefixPath)
                return
            }
            setWindowsStatus("Cannot launch: the installed Steam client build is not supported by Madeira Dock. Reinstall a verified client rather than bypassing Steam licensing.")
            return
        }
        currentSteamLaunchUsesDock = false
        dockLaunchAccepted = false
        steamDockLaunchStage = nil
        pendingSteamGameID = game.appID
        directSteamStartedAt = Date()
        setWindowsStatus("Launching Steam game...")
        withPreparedMetalDisplay(expectedStatus: "Launching Steam game...") { [weak self] in
            guard let self, self.pendingSteamGameID == game.appID else { return }
            guard self.windowsStatus == "Launching Steam game..." else {
                self.pendingSteamGameID = nil
                return
            }
            guard !ideck_wineprocess_running() else {
                self.pendingSteamGameID = nil
                self.setWindowsStatus("Execution Error: another Wine process started during game preparation.")
                return
            }
            self.captureWineLogStart()
            self.windowsEnvironment.execute(binary: executableURL,
                                            arguments: profile.arguments.isEmpty ? entryArguments : profile.arguments,
                                            steamAppID: game.appID,
                                            steamInstallDirectory: directory,
                                            steamWorkingDirectory: selected.workingDirectory,
                                            jitEnabler: self.jitEnabler) { [weak self] success in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingSteamGameID = nil
                    let running = success == 0 && ideck_wineprocess_running()
                    if running {
                        self.activeSteamGameID = game.appID
                        self.activeSteamPrefix = standardizedPrefix
                    } else {
                        self.activeSteamGameID = nil
                        self.activeSteamPrefix = nil
                    }
                    if self.windowsStatus == "Launching Steam game..." {
                        // Wine reports its loader thread as running before
                        // the requested game's executable reaches first frame.
                        self.setWindowsStatus(running
                            ? "Wine started; waiting for game..." : self.nativeLaunchFailure(success))
                    }
                }
            }
        }
    }

    /// Starts an installed Steam game through Valve's own Windows client
    /// (Madeira Dock): Valve's client signs in, checks the licence and starts
    /// the game with its DRM untouched.
    /// Status shown on the game's loading screen while Steam's client
    /// components download before the first Steam game starts.
    static let steamComponentsInstallStatus = "Installing Steam client components..."

    /// Prepare Valve's verified client components before the first Steam
    /// game launch. Never silently fall back to the direct EXE: that would
    /// bypass the official launch path needed by licensed/DRM games.
    private func installSteamComponentsThenLaunch(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
        setWindowsStatus(Self.steamComponentsInstallStatus)
        steamComponentsProgress = nil
        let running = steamComponentsTask
        Task { @MainActor [weak self] in
            await running?.value
            var failure: String?
            if !MadeiraDock.clientInstalled {
                let owner = self
                do {
                    try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("wine", isDirectory: true)) { message in
                        AppLog.record("[steam-components] " + message)
                        await MainActor.run { owner?.steamComponentsProgress = message }
                    }
                } catch {
                    failure = error.localizedDescription
                }
            }
            // An already installed Steam client may still have an x86 or
            // malformed SDL3.dll, or be missing video64.dll's FFmpeg imports.
            // Recheck immediately before the Dock session, not only when the
            // library workspace opens. Never modify a running Wine session.
            if MadeiraDock.clientInstalled {
                let root = MadeiraDock.prefix
                let repair = await Task.detached(priority: .utility) {
                    SteamDLLRepair.repair(prefix: root)
                }.value
                if !repair.copied.isEmpty {
                    AppLog.record("[steam-dll] repaired before Steam launch: " + repair.copied.joined(separator: ", "))
                }
                if !repair.invalid.isEmpty {
                    AppLog.record("[steam-dll] incompatible DLLs preserved or repair failed: " + repair.invalid.joined(separator: ", "))
                }
                if !repair.missing.isEmpty {
                    AppLog.record("[steam-dll] missing before launch: " + repair.missing.joined(separator: ", ")
                                  + "; import matching genuine Steam x64 DLLs into Documents/SteamDLLs")
                }
            }
            guard let self, self.windowsStatus == Self.steamComponentsInstallStatus else { return }
            self.steamComponentsProgress = nil
            if MadeiraDock.clientInstalled && MadeiraDock.clientSupported {
                self.launchThroughDock(game: game, profile: profile, prefixPath: prefixPath)
            } else {
                let problem = failure ?? "unsupported Steam client build"
                AppLog.record("[steam-components] client preparation failed: \(problem)")
                self.setWindowsStatus("Cannot launch: the official Steam client could not be prepared (\(problem)). No direct DRM fallback was attempted.")
            }
        }
    }

    /// Steam's client loads its own ~25 MiB of DLLs plus a browser helper on
    /// top of the game: below this pool it runs out of executable memory
    /// (every DLL fails with STATUS_NO_MEMORY) and the session dies.
    static let dockMinimumPoolMiB: UInt32 = 512

    /// Prepares Wine's JIT pool before a Steam client session and checks it is
    /// large enough. The components download can outlast StikDebug's
    /// attachment, so this runs again right before the client starts.
    private func launchThroughDock(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
        jitResume = { [weak self] in self?.launchThroughDock(game: game, profile: profile, prefixPath: prefixPath) }
        guard ensureJITForGameLaunch() else { return }
        startDockSession(game: game, profile: profile, prefixPath: prefixPath)
    }

    /// Madeira's Dock start (ContentView.startDock), with Madeira's own files
    /// (MadeiraDock/): validation, the app's connection logged off, the sign-in
    /// transfer, the host's environment, then the game's one-time installs. A
    /// start with installs runs only them (madeira-bcd: DockInstallers.installsOnly);
    /// the game starts after a restart of iDeck.
    private func startDockSession(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
        // The JIT pool list (Documents/jit-pool.txt) names games by App ID and program.
        setenv("IDECK_JIT_GAME_STEAM", String(game.appID), 1)
        let drive = MadeiraDock.drive
        guard let dockGame = MadeiraDock.game(appID: game.appID) else {
            setWindowsStatus("Cannot launch: Steam's completed appmanifest was not found.")
            return
        }
        do {
            try MadeiraDock.validate(dockGame, drive: drive)
            guard SteamSignIn.isSignedIn else { throw DockError.message("Sign in to Steam to start games through Steam.") }
        } catch {
            setWindowsStatus("Cannot launch: " + error.localizedDescription)
            return
        }
        currentSteamLaunchUsesDock = true
        dockLaunchAccepted = false
        steamDockLaunchStage = "Starting Madeira Dock..."
        steamDockStartedAt = ProcessInfo.processInfo.systemUptime
        let standardizedPrefix = prefixPath.standardizedFileURL.path
        pendingSteamGameID = game.appID
        setWindowsStatus("Launching Steam game...")
        // As Madeira (SteamConnectionGate.holdForDock): Valve's client must be the
        // only connection logged on with this account; iDeck's own logs off first.
        Task { @MainActor [weak self] in
            await SteamOwnedGamesModel.shared.holdForDock()
            guard let self else { return }
            let program: URL
            let arguments: String
            do {
                guard let signIn = SteamSignIn.credentialsForDock() else {
                    throw DockError.message("Sign in to Steam to start games through Steam.")
                }
                try MadeiraDock.writeHandoff(account: signIn.accountName, token: signIn.refreshToken, appID: dockGame.id)
                let launchOption = self.gameLaunchOption(game, prefixPath: prefixPath)
                if launchOption == 0 { self.skipGameLauncher(game, prefixPath: prefixPath) }
                MadeiraDock.configure(dockGame, launchOption: launchOption, arguments: profile.arguments)
                // Visual C++ is built into iDeck: Steam's Visual C++ installers count as run.
                MadeiraDock.markBundledVisualCRuns(dockGame)
                DockInstallers.prepare(dockGame, drive: drive, prefix: MadeiraDock.prefix,
                                       others: MadeiraDock.games(drive: drive))
                if DockInstallers.script != nil, MadeiraDock.stageCommandShell() == nil {
                    // A missing or invalid cmd.exe cannot run the Steamworks
                    // install script. Never forge its HasRun registry values:
                    // that made a failed prerequisite appear installed.
                    // The game itself still starts: Visual C++ is built into
                    // iDeck and most games need nothing else. Blocking here
                    // left games such as Bully unable to start at all.
                    SteamLog.event("[dock-installers] skipped: valid Windows cmd.exe unavailable; prerequisites remain pending, starting the game")
                    DockInstallers.skipScript()
                }
                if DockInstallers.installsOnly, let script = DockInstallers.script {
                    // No host runs in this session: nothing will take the sign-in transfer.
                    MadeiraDock.cleanup()
                    setenv("MADEIRA_DOCK_INSTALLS_SESSION", "1", 1)
                    program = try MadeiraDock.stageCommandShell().orThrow(DockError.message("This build has no cmd.exe for Steam's one-time installs."))
                    arguments = "/c call " + script
                    SteamLog.event("[madeira-dock] app \(dockGame.id): this session runs only the one-time installs")
                } else {
                    unsetenv("MADEIRA_DOCK_INSTALLS_SESSION")
                    let host = try MadeiraDock.stageHost()
                    if let script = DockInstallers.script {
                        program = try MadeiraDock.stageCommandShell().orThrow(DockError.message("This build has no cmd.exe for Steam's one-time installs."))
                        arguments = "/c call \(script) & \(MadeiraDock.executable)"
                    } else {
                        program = host
                        arguments = ""
                    }
                }
            } catch {
                MadeiraDock.cleanup()
                SteamOwnedGamesModel.shared.releaseDock()
                self.pendingSteamGameID = nil
                self.setWindowsStatus("Cannot launch: " + error.localizedDescription)
                return
            }
            if DockInstallers.serverSync { setenv("MADEIRA_MADSYNC_SESSION", "0", 1) } else { unsetenv("MADEIRA_MADSYNC_SESSION") }
            // As Madeira: a Dock session's later programs are often 32-bit and need the
            // GDI handle table as a shared section. madeira.cfg can still turn it off.
            setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)
            if DockInstallers.installsOnly {
                self.activeSteamInstallerAppID = game.appID
                self.steamPrerequisiteProgress = DockInstallers.note ?? "Running Steam's one-time installs..."
            }
            self.continueDockSession(game: game, program: program, arguments: arguments,
                                     installsOnly: DockInstallers.installsOnly, standardizedPrefix: standardizedPrefix)
        }
    }

    private func continueDockSession(game: SteamAppInfo, program: URL, arguments: String, installsOnly: Bool,
                                     standardizedPrefix: String) {
        withPreparedMetalDisplay(expectedStatus: "Launching Steam game...") { [weak self] in
            guard let self, self.pendingSteamGameID == game.appID else { return }
            guard !ideck_wineprocess_running() else {
                self.pendingSteamGameID = nil
                self.setWindowsStatus("Execution Error: another Wine process started during game preparation.")
                return
            }
            self.captureWineLogStart()
            // The game's folder, so its fixed-base exe is measured before the JIT pool is
            // placed: the program started here is Madeira Dock's host, not the game.
            let steamApps = SteamInstallPaths.steamApps(drive: MadeiraDock.drive)
            let folderName = SteamInstallFiles.installDirectoryName(appID: Int(game.appID), steamApps: steamApps)
                ?? SteamInstallFiles.safeFolderName(game.installDir.isEmpty ? "app_\(game.appID)" : game.installDir)
            let gameFolder = SteamInstallPaths.common(drive: MadeiraDock.drive).appendingPathComponent(folderName, isDirectory: true)
            self.windowsEnvironment.execute(binary: program, arguments: arguments,
                                            steamInstallDirectory: installsOnly ? nil : gameFolder,
                                            jitEnabler: self.jitEnabler) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingSteamGameID = nil
                    let running = status == 0 && ideck_wineprocess_running()
                    self.activeSteamGameID = running ? game.appID : nil
                    self.activeSteamPrefix = running ? standardizedPrefix : nil
                    self.dockSessionActive = running && !installsOnly
                    if running && !installsOnly { self.watchDockReport() }
                    if self.windowsStatus == "Launching Steam game..." {
                        self.setWindowsStatus(running
                            ? (installsOnly ? "Installing Steam prerequisites..." : "Wine started; waiting for game...")
                            : self.nativeLaunchFailure(status))
                    }
                }
            }
        }
    }

    /// The session of one-time installs ended (Wine and wineserver both exited,
    /// so the registry is on disk): Madeira's restart notice.
    @discardableResult
    private func finishSteamPrerequisiteSession() -> Bool {
        guard activeSteamInstallerAppID != nil,
              !ideck_wineprocess_running(), !ideck_wineserver_running(),
              ideck_wineprocess_thread_finished(), ideck_runtime_complete_session() else { return false }
        activeSteamInstallerAppID = nil
        pendingSteamGameID = nil
        activeSteamGameID = nil
        activeSteamPrefix = nil
        activeWindowsProfile = nil
        let ended = MainActor.assumeIsolated { DockInstallers.poll(drive: MadeiraDock.drive) }
        let message = MainActor.assumeIsolated { DockInstallers.restartNotice(ended) }
            .replacingOccurrences(of: "Madeira", with: "iDeck")
        steamPrerequisiteProgress = nil
        MainActor.assumeIsolated { SteamOwnedGamesModel.shared.releaseDock() }
        SteamLog.event("[dock-installers] \(message)")
        isClosingWindowsSession = false
        windowsCloseRequestedAt = nil
        windowsCloseWarning = nil
        windowsCloseWarningWasShown = false
        windowsStatusBeforeClose = nil
        setWindowsStatus(message)
        return true
    }

    /// Follows the host's numeric report and shows its failure, if any.
    private func watchDockReport(remaining: Int = 600) {
        guard remaining > 0, ideck_wineprocess_running() else {
            MainActor.assumeIsolated { MadeiraDock.cleanup() }
            return
        }
        let report = MainActor.assumeIsolated { MadeiraDock.pollReport() }
        MainActor.assumeIsolated { DockOffline.observe(report.fields) }
        let elapsed = ProcessInfo.processInfo.systemUptime - (steamDockStartedAt ?? ProcessInfo.processInfo.systemUptime)
        steamDockLaunchStage = IDeckDockStartStatus.text(report.fields, waited: elapsed)
        dockLaunchAccepted = report.fields["launch-client-error"] == "0"
        if let failure = report.failure {
            dockSessionActive = false
            finishMemorySampling(reason: "Steam: " + failure)
            setWindowsStatus("Steam: " + failure)
            MainActor.assumeIsolated { MadeiraDock.cleanup() }
            return
        }
        if report.result == 0 {
            dockSessionActive = false
            MainActor.assumeIsolated { MadeiraDock.cleanup() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.watchDockReport(remaining: remaining - 1)
        }
    }

    // Wine is hosted in a thread of the iDeck process; native state may
    // remain live for some time after the guest's running flag becomes false.
    // Reject a new launch before any prefix/JIT/Metal preparation until the
    // pinned Wine worker and the in-app wineserver have both exited.
    /// Polls the native session release for up to `timeout` seconds. The pool
    /// and the previous session's image copies are only reused after this
    /// returns true (ideck_runtime_complete_session saw both threads stopped).
    private func waitForSessionCleanup(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if ideck_wineprocess_thread_finished() && ideck_wineserver_running() {
                _ = ideck_wineserver_stop_if_idle()
            }
            if ideck_runtime_complete_session() { return true }
            if ideck_wineprocess_running() || Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// When a Windows session has ended (an installer finished or was stopped, a game
    /// closed), frees its JIT pool as soon as the Wine worker and the wineserver have
    /// stopped. A launch that failed before Wine started keeps the pool for the retry.
    private func releaseJITPoolAfterSession(remaining: Int = 40) {
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

    private func previousWineSessionStillFinishing() -> Bool {
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
                setWindowsStatus("Execution Error: \(why). Restart iDeck before starting another game: swipe iDeck away in the app switcher, then open it again through StikDebug.")
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

    private func finishWindowsSessionCloseIfPossible() {
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

    /// Frees what a finished session held and iDeck rebuilds on demand: the GOG
    /// Galaxy service, Madeira Dock's leftovers, cached responses and artwork, and
    /// the Metal caches the governor owns. Safe to call more than once.
    /// When the session that is ending started: temporary files from before it are stale.
    private var sessionTempCutoff = Date.distantPast

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

    /// Why the next game needs a fresh iDeck process, or nil. Wine runs inside iDeck:
    /// after a crashed session, on a shrunken JIT pool or with little memory left, a
    /// second game started in the same process failed (BioShock after Dragon Age:
    /// 6108 MB in use, a 336 MB pool, a crash inside the runtime).
    static var restartReason: String?
    static let restartMinimumFreeMiB = 1500

    static func restartNeeded() -> String? {
        if let restartReason { return restartReason }
        if WindowsEnvironment.oneSessionPerRun && WindowsEnvironment.sessionsThisRun > 0 {
            return "this runtime requires a fresh iDeck process for each Windows session"
        }
        // A pool that had to shrink is not a reason: it happens on a fresh launch too
        // (the startup pool keeps a 256 MB exe window free), so reopening changes nothing.
        let free = Int(os_proc_available_memory() >> 20)
        if free > 0 && free < restartMinimumFreeMiB { return "only \(free) MB of memory is left" }
        return nil
    }

    static let cleanupStuckMessage = "Execution Error: the previous Windows session did not finish closing. Wine runs inside iDeck, so restart iDeck to start another game: swipe iDeck away in the app switcher, then open it again."
    static let restartMessage = "Execution Error: restart iDeck to start another game: swipe iDeck away in the app switcher, then open it again."

    private func nativeLaunchFailure(_ status: Int) -> String {
        if status == 0 || status == Int(EAGAIN) {
            return wineExitResult().reason
        }
        if status == Int(EALREADY) {
            return ideck_wineprocess_running()
                ? "A Windows session is already running. Close it before starting another game."
                : Self.cleanupStuckMessage
        }
        if status == Int(ENOTSUP) {
            return "Execution Error: 32-bit Windows support (WoW64) is missing from this IPA."
        }
        if status == Int(EPERM) {
            return "Execution Error: FEX/Wine JIT requires StikDebug to stay attached until both executable-memory pools are prepared. Request JIT inside iDeck with its bundled debugger script."
        }
        if status == Int(ENOENT) {
            return "Execution Error: Wine prefix or runtime components are missing."
        }
        if status == Int(EINVAL) {
            return isSteamSession
                ? "Execution Error: invalid Windows launch request (code 22). Check the executable format, Steam game metadata and launch arguments. The iDeck console identifies rejected native parameters under [iDeck native launch] EINVAL or [wine-launch]."
                : "Execution Error: invalid Windows launch request (code 22). Check the executable format and launch arguments. The iDeck console identifies rejected native parameters under [iDeck native launch] EINVAL or [wine-launch]."
        }
        if status == Int(ENOMEM), let reason = WindowsEnvironment.lastPoolFailure {
            return "Execution Error: " + reason
        }
        if status == Int(ENOMEM) {
            let machCode = ideck_wine_jit_pool_failure_mach_code()
            let machDetail = machCode == 0 ? "" : " (Mach code \(machCode))"
            switch ideck_wine_jit_pool_failure_stage() {
            case 1:
                return "Execution Error: StikDebug disconnected before Wine could prepare executable memory. Request JIT from iDeck with the bundled BRK script."
            case 2:
                return "Execution Error: StikDebug could not allocate the Wine executable RX region, including smaller pools. Keep the debugger attached and check available virtual memory."
            case 3:
                let cause: String
                switch ideck_wine_jit_pool_failure_rx_detail() {
                case 1: cause = "The JIT RX address is below Madeira's required FEX frontier."
                case 2: cause = "The RX address range overflowed."
                case 3: cause = "The RX region exceeds the supported virtual-memory layout."
                case 4: cause = "The RX region overlaps the Windows executable-image address window."
                case 5: cause = "The RX region is not page-aligned."
                case 6: cause = "Mach could not inspect the RX region."
                case 7: cause = "The RX region contains an unmapped gap."
                case 8: cause = "A page in the RX region lacks executable permission."
                default: cause = "The RX region failed validation."
                }
                return "Execution Error: Wine's RX pool was rejected: \(cause) Restart iDeck, request StikDebug JIT from Madeira and check [iDeck Wine JIT] logs. Do not reuse a JIT pool after a crash."
            case 4:
                return "Execution Error: Wine's executable RX region was allocated, but iPadOS denied its writable RW mirror\(machDetail). Check [iDeck Wine JIT] logs."
            case 5:
                return "Execution Error: iPadOS denied write access to the Wine JIT RW mirror\(machDetail). Check [iDeck Wine JIT] logs."
            case 6:
                return "Execution Error: Wine JIT memory exists, but the RX/RW addresses could not be exported to the guest environment."
            default:
                return "Execution Error: the Wine ARM64EC executable JIT pool could not be prepared. Check the [iDeck Wine JIT] diagnostics."
            }
        }
        let message = status > 0 && status < 256
            ? String(cString: strerror(Int32(status))) : "unknown native error"
        return "Execution Error: Madeira launch failed (code \(status): \(message))."
    }

    /// Steam's launch option for the game itself. When Steam's default option
    /// opens a launcher, the first Windows option that starts the game's own
    /// executable (installed in the game folder) is used instead.
    func gameLaunchOption(_ game: SteamAppInfo, prefixPath: URL) -> UInt32 {
        let windows = game.launches.filter { option in
            let platforms = option.oslist.lowercased()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            return (platforms.isEmpty || platforms.contains("windows")) && (option.requiredDLC?.isEmpty != false)
        }
        func isLauncher(_ option: SteamLaunchOption) -> Bool {
            let exe = option.executable.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").last.map { $0.lowercased() } ?? ""
            return option.type.lowercased().contains("launcher") || exe.contains("launcher")
        }
        guard let first = windows.first, isLauncher(first) else { return 0 }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        let name = SteamInstallFiles.installDirectoryName(appID: Int(game.appID), steamApps: steamApps) ??
            SteamInstallFiles.safeFolderName(game.installDir)
        let root = SteamInstallPaths.common(drive: drive).appendingPathComponent(name, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let special = ["vr", "server", "editor", "tool"]
        let direct = windows.filter { option in
            !isLauncher(option) && option.index != nil &&
            !special.contains(where: { option.type.lowercased().contains($0) }) &&
            SteamInstallFiles.resolveLaunchPath(option.executable, root: root, executable: true) != nil
        }.sorted { ($0.osarch == "64" ? 0 : 1) < ($1.osarch == "64" ? 0 : 1) }
        guard let pick = direct.first, let index = pick.index else { return 0 }
        SteamLog.event("[steam-compat] app=\(game.appID) launcher skipped; launch option \(index) (\(pick.executable))")
        return index
    }

    /// When Steam can only start a game through its launcher (Skyrim SE's
    /// SkyrimSELauncher.exe, Fallout 4's Fallout4Launcher.exe), the launcher
    /// file is replaced by a copy of the game's own executable next to it
    /// (the original is kept as `<name>.ideck-launcher`). Steam then starts
    /// the game directly and no launcher window stays on screen.
    func skipGameLauncher(_ game: SteamAppInfo, prefixPath: URL) {
        let windows = game.launches.filter { option in
            let platforms = option.oslist.lowercased()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            return (platforms.isEmpty || platforms.contains("windows")) && (option.requiredDLC?.isEmpty != false)
        }
        guard let first = windows.first else { return }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        let name = SteamInstallFiles.installDirectoryName(appID: Int(game.appID), steamApps: steamApps) ??
            SteamInstallFiles.safeFolderName(game.installDir)
        let root = SteamInstallPaths.common(drive: drive).appendingPathComponent(name, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard let launcher = SteamInstallFiles.resolveLaunchPath(first.executable, root: root, executable: true) else { return }
        let file = launcher.lastPathComponent
        guard let range = file.range(of: "launcher", options: .caseInsensitive) else { return }
        var gameName = file
        gameName.removeSubrange(range)
        let folder = launcher.deletingLastPathComponent()
        let fm = FileManager.default
        guard gameName.lowercased().hasSuffix(".exe"), gameName.count > 4,
              let gameFile = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .first(where: { $0.caseInsensitiveCompare(gameName) == .orderedSame }) else { return }
        let gameExe = folder.appendingPathComponent(gameFile)
        let backup = folder.appendingPathComponent(file + ".ideck-launcher")
        do {
            if fm.contentsEqual(atPath: gameExe.path, andPath: launcher.path) { return }
            // An update restored the real launcher: keep that one as the backup.
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.moveItem(at: launcher, to: backup)
            try fm.copyItem(at: gameExe, to: launcher)
            SteamLog.event("[steam-compat] app=\(game.appID) launcher \(file) now starts \(gameFile)")
        } catch {
            if !fm.fileExists(atPath: launcher.path) { try? fm.moveItem(at: backup, to: launcher) }
            SteamLog.event("[steam-compat] app=\(game.appID) launcher skip failed: \(error.localizedDescription)")
        }
    }

    /// Reads only metadata already available to iDeck and filenames inside
    /// the installed game. This does not connect to Steam or block an EXE.
    func steamLaunchWarning(game: SteamAppInfo, prefixPath: URL) -> String? {
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        guard SteamInstallFiles.buildID(appID: Int(game.appID), steamApps: steamApps) != nil else {
            return nil
        }
        let name = SteamInstallFiles.installDirectoryName(
            appID: Int(game.appID), steamApps: steamApps) ??
            SteamInstallFiles.safeFolderName(game.installDir)
        let directory = SteamInstallPaths.common(drive: drive)
            .appendingPathComponent(name, isDirectory: true)
        guard let selected = steamExecutable(game: game, directory: directory) else {
            return nil
        }
        let manager = FileManager.default
        let rootNames = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        let workNames = selected.workingDirectory.path == directory.path ? [] :
            ((try? manager.contentsOfDirectory(atPath: selected.workingDirectory.path)) ?? [])
        let finding = SteamLaunchCompatibility.classify(
            executable: selected.url.lastPathComponent,
            launchType: selected.type,
            localEntries: Array((rootNames + workNames).prefix(1024)))
        SteamLog.event("[steam-compat] app=\(game.appID) source=\(selected.source) class=\(finding.kind.rawValue)")
        return finding.warning
    }

    private func steamExecutable(game: SteamAppInfo, directory: URL)
        -> (url: URL, arguments: String, workingDirectory: URL, source: String, type: String)? {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL

        let preferred = game.launches.enumerated().filter { _, option in
            let platforms = option.oslist.lowercased()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            return (platforms.isEmpty || platforms.contains("windows")) &&
                   (option.requiredDLC?.isEmpty != false)
        }.sorted { left, right in
            // Prefer the normal Windows game over editors, tools and VR,
            // retaining Valve's configuration order for equal priorities.
            func priority(_ option: SteamLaunchOption) -> Int {
                let type = option.type.lowercased()
                let special = ["vr", "server", "editor", "launcher", "tool"]
                    .contains(where: { type.contains($0) })
                let arch64 = option.osarch == "64"
                return (special ? 100 : 0) + (arch64 ? 0 : 10)
            }
            let a = priority(left.element), b = priority(right.element)
            return a == b ? left.offset < right.offset : a < b
        }

        for (_, option) in preferred {
            guard let executable = SteamInstallFiles.resolveLaunchPath(
                option.executable, root: root, executable: true) else { continue }
            let requestedDir = option.workingDir.trimmingCharacters(in: .whitespacesAndNewlines)
            let workdir: URL
            if requestedDir.isEmpty {
                workdir = executable.deletingLastPathComponent()
            } else if let resolved = SteamInstallFiles.resolveLaunchPath(
                requestedDir, root: root, executable: false) {
                workdir = resolved
            } else {
                // Steam can provide a stale/unsupported workingdir. Keep
                // relative DLL and asset lookups inside the EXE's folder.
                SteamLog.event("[steam-start] app=\(game.appID) invalid workingdir for option \(option.index ?? 0); using exe directory")
                workdir = executable.deletingLastPathComponent()
            }
            return (executable, option.arguments, workdir,
                    "steam-config-\(option.index ?? 0)", option.type)
        }

        let blockedNames = Set([
            "unins000.exe", "uninstall.exe", "setup.exe", "install.exe",
            "crashreporter.exe", "unitycrashhandler64.exe",
            "unitycrashhandler32.exe", "dxsetup.exe", "vcredist.exe",
            "steamsetup.exe", "vc_redist.x64.exe", "vc_redist.x86.exe"
        ])
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var candidates: [(url: URL, score: Int)] = []
        var visited = 0
        let expectedNames = [game.installDir, game.name]
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
        for case let entry as URL in enumerator {
            visited += 1
            if visited > 20_000 || candidates.count >= 256 { break }
            guard entry.pathExtension.lowercased() == "exe",
                  !blockedNames.contains(entry.lastPathComponent.lowercased()),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(resolved.path.dropFirst(root.path.count + 1))
            guard relative.split(separator: "/").count <= 6 else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
                .lowercased().filter { $0.isLetter || $0.isNumber }
            let depth = relative.split(separator: "/").count
            let isLikelyGame = expectedNames.contains(basename)
            let isTool = relative.lowercased().contains("redist") ||
                         relative.lowercased().contains("prereq") ||
                         relative.lowercased().contains("engine/binaries") ||
                         basename.contains("crash") || basename.contains("uninstall")
            let score = (isLikelyGame ? 100 : 0) + (isTool ? -100 : 0) -
                        depth * 10
            candidates.append((resolved, score))
        }
        guard let best = candidates.sorted(by: {
            $0.score == $1.score
                ? $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
                : $0.score > $1.score
        }).first, best.score > -100 else { return nil }
        SteamLog.event("[steam-start] app=\(game.appID) using executable fallback; Steam metadata did not resolve")
        return (best.url, "", best.url.deletingLastPathComponent(), "installed-files", "")
    }

    /// Links the saved external folders into the prefix before Wine starts.
    func mountExternalDrives(prefix: String) {
        let url = URL(fileURLWithPath: prefix, isDirectory: true)
        if Thread.isMainThread {
            MainActor.assumeIsolated { ExternalDrives.shared.mountAll(prefix: url) }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { ExternalDrives.shared.mountAll(prefix: url) } }
        }
    }


}

/// Rockstar Games Launcher, installed by iDeck when a Rockstar game is installed from
/// Steam or Epic Games (2.13.3). Rockstar's games start it and will not run without
/// it; their own first start ran its installer in Wine, whose 32-bit Visual C++
/// setup failed (GTA IV, 2026-11-23). It is not a store: it has no library page and
/// no Settings entry. Copied without Wine, as Ubisoft Connect is
/// (StoreClient.installWithoutWine); an installer iDeck cannot open is logged and
/// left to the game, as before.
enum RockstarLauncher {
    static let installFolder = "Program Files/Rockstar Games/Launcher"
    static let downloadURL = URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!
    static let installerName = "Rockstar-Games-Launcher.exe"
    /// Programs only Rockstar's games ship (their own launchers).
    static let gameMarkers: Set<String> = ["playgtav.exe", "playrdr2.exe", "playgtaiv.exe", "launchgtaiv.exe",
                                           "playmaxpayne3.exe", "playlanoire.exe", "rockstar-games-launcher.exe"]

    static func installed(drive: URL) -> Bool {
        FileManager.default.fileExists(atPath: drive.appendingPathComponent(installFolder).appendingPathComponent("Launcher.exe").path)
    }

    /// Whether `folder` holds a Rockstar game, and the launcher installer it ships, if any.
    static func scan(_ folder: URL) -> (isRockstar: Bool, installer: URL?) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return (false, nil) }
        var found = false
        var installer: URL?
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 20_000 { break }
            if walker.level > 3 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            guard gameMarkers.contains(name) else { continue }
            found = true
            if name == installerName.lowercased() { installer = url; break }
        }
        return (found, installer)
    }

    /// Installs the launcher after a game install, when the game is Rockstar's and the
    /// launcher is missing. Never throws: a failure is logged and the game keeps its own path.
    static func installIfNeeded(gameFolder: URL, drive: URL = SystemCoordinator.StoreClient.drive) async {
        let found = await Task.detached(priority: .utility) { scan(gameFolder) }.value
        guard found.isRockstar, !installed(drive: drive) else { return }
        let fm = FileManager.default
        let work = drive.appendingPathComponent("iDeck", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            var installer = found.installer
            if installer == nil {
                let target = work.appendingPathComponent(installerName)
                let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? fm.removeItem(at: temporary)
                    throw CocoaError(.fileReadUnknown)
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: temporary, to: target)
                installer = target
            }
            guard let source = installer else { return }
            let staging = work.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            let target = staging.appendingPathComponent(installFolder, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) {
                var message = [CChar](repeating: 0, count: 512)
                let count = message.withUnsafeMutableBufferPointer {
                    ideck_nsis_extract(source.path, target.path, $0.baseAddress!, $0.count)
                }
                if count < 0 { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: String(cString: message)]) }
                try SystemCoordinator.StoreClient.merge(staging, into: drive)
            }.value
            guard installed(drive: drive) else {
                AppLog.record("[rockstar-launcher] files copied but Launcher.exe is missing; the game installs it itself")
                return
            }
            writeRegistry()
            AppLog.record("[rockstar-launcher] installed without Wine for \(gameFolder.lastPathComponent)")
        } catch {
            AppLog.record("[rockstar-launcher] not installed (\(error.localizedDescription)); the game installs it itself")
        }
    }

    /// Where Rockstar's games look for the launcher. Written while no session runs.
    static func writeRegistry(prefix: URL = MadeiraDock.prefix) {
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        let folder = "C:\\" + installFolder.replacingOccurrences(of: "/", with: "\\")
        let values = ["Software\\Rockstar Games\\Launcher", "Software\\Wow6432Node\\Rockstar Games\\Launcher"].map {
            SteamInstallValue(hive: .machine, key: $0, name: "InstallFolder", data: .string(folder), followsInstall: true)
        }
        do {
            let changed = try EARegistry.write(values, prefix: prefix)
            AppLog.record("[rockstar-launcher] \(changed) registry line(s) written")
        } catch {
            AppLog.record("[rockstar-launcher] registry not written: \(error.localizedDescription)")
        }
    }
}
