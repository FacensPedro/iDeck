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

    private static var wineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.txt", isDirectory: false)
    }

    /// madeira-log.txt grows by every session (Madeira opens it for appending) and was
    /// never cut. Between sessions, while no Wine runs, a log past this size becomes
    /// madeira-log.previous.txt (one kept), so it stays fast to scan and copy.
    static let wineLogRotateBytes: Int64 = 24 << 20

    static func rotateWineLogIfLarge(_ url: URL) {
        guard !ideck_wineprocess_running(), !ideck_wineserver_running(),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > wineLogRotateBytes else { return }
        let previous = url.deletingLastPathComponent().appendingPathComponent("madeira-log.previous.txt")
        try? FileManager.default.removeItem(at: previous)
        if (try? FileManager.default.moveItem(at: url, to: previous)) != nil {
            AppLog.record("[wine-log] madeira-log.txt reached \(size >> 20) MB: kept as madeira-log.previous.txt")
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
        let childAV: Bool
        if code == 0, nativeStatus == nil,
           let start = wineLogStartOffset, let path = Self.wineLogURL?.path {
            childAV = path.withCString { ideck_wine_log_fatal_av_since($0, start) != 0 }
        } else {
            childAV = false
        }
        let effectiveStatus = nativeStatus ?? (childAV ? UInt32(0xC0000005) : nil)
        var reason = WineExitDiagnostics.message(exitCode: code, crashStatus: effectiveStatus)
        if childAV {
            reason += " Wine's host returned exit code 0, but a Windows child process terminated with an access violation."
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
    private func recordGameContext(_ title: String, launcher: String) {
        let clean = title.replacingOccurrences(of: "[\\r\\n]", with: " ", options: .regularExpression)
        let safeTitle = String(clean.prefix(160))
        UserDefaults.standard.set(safeTitle, forKey: "diagnostics.lastGame")
        UserDefaults.standard.set(launcher, forKey: "diagnostics.lastLauncher")
        AppLog.record("[game-session] launcher=\(launcher) game=\(safeTitle)")
    }

    @Published private(set) var activeWindowsProfile: WindowsGameProfile?
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
                    try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { [weak self] message in
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
        recordBenchmarkMilestone(status)
        let update = {
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
                // As Madeira: the pool is allocated at launch (MadeiraWinePool),
                // not when the debugger attaches.
                self.wineJITAttemptedDuringAttachment = true
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

    private func waitForDebuggerThenResume(_ resume: @escaping () -> Void) {
        pendingJITLaunch = resume
    }

    /// Madeira's readiness: StikJITHelper.ready (CS_DEBUGGED and a live
    /// debugger) or a pool already exported. The pool itself is allocated at
    /// launch (MadeiraWinePool), followed by Madeira's early detach.
    @discardableResult
    private func ensureJITForGameLaunch() -> Bool {
        guard AddressSpaceCheck.hasGuestWindow else {
            jitResume = nil
            AppLog.record("[address-space] no mapping at 0x7000000000: extended virtual addressing is not active")
            setWindowsStatus(AddressSpaceCheck.message)
            return false
        }
        let resume = jitResume
        jitResume = nil
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
            + "pool=\(ideck_wine_jit_pool_ready() ? 1 : 0) at \(ISO8601DateFormatter().string(from: Date()))"
        UserDefaults.standard.set(text, forKey: lastLaunchJITKey)
        AppLog.record("[jit] preparation validated for launch: \(text)")
    }

    /// Runs the pending launch once the debugger is attached, or reports why not.
    private func finishJITRequest(_ result: Result<Void, Error>) {
        refreshJITStatus()
        jitRequestStartedAt = nil
        let launch = pendingJITLaunch
        pendingJITLaunch = nil
        switch result {
        case .success:
            AppLog.record("[jit] debugger attached; continuing the launch")
            launch?()
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
            setWindowsStatus("Import a pairing file in Settings › JIT before using the built-in JIT.")
            return
        }
        guard let scriptURL = Bundle.main.url(forResource: "universal", withExtension: "jitscript"),
              let script = try? Data(contentsOf: scriptURL), !script.isEmpty else {
            setWindowsStatus("Cannot request JIT: the bundled universal.js debugger script is missing.")
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
                    if !response.success { self.setWindowsStatus("Built-in JIT: " + response.message) }
                case .failure(let error):
                    self.setWindowsStatus("Built-in JIT: " + error.localizedDescription)
                }
            }
        }
    }

    /// When the JIT request in flight was started (nil: none). A second request
    /// within 20 s joins it instead of opening StikDebug again.
    private var jitRequestStartedAt: Date?

    /// For launches that first need a network round trip (Epic's and EA's launch
    /// tokens): starts JIT activation at once, in parallel with it, so StikDebug
    /// opens on the tap instead of after the store answers. The launch itself still
    /// goes through ensureJITForGameLaunch and waits for the validated preparation.
    func prewarmJITForLaunch() {
        guard MadeiraBundleIdentity.isNative, AddressSpaceCheck.hasGuestWindow,
              StikJITHelper.scriptData != nil, !isClosingWindowsSession else { return }
        refreshJITStatus()
        guard !Self.jitPreparationValidated() else { return }
        setWindowsStatus("JIT is not enabled for this iDeck process. Opening StikDebug...")
        requestStikDebugJIT()
    }

    func requestStikDebugJIT() {
        if let started = jitRequestStartedAt, Date().timeIntervalSince(started) < 20 { return }
        jitRequestStartedAt = Date()
        if jitMethod == "builtIn", FileManager.default.fileExists(atPath: pairingFileURL.path), MainActor.assumeIsolated({ IDeckBuiltInJIT.isAvailable }) {
            requestBuiltInJIT()
            StikJITHelper.waitForDebugger { [weak self] result in
                DispatchQueue.main.async { self?.finishJITRequest(result) }
            }
            return
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
        // Visual C++ built into a development app: in place without installing anything.
        if let documents { VisualCRuntimeBootstrap.installBundled(documents: documents) }
        guard let executable, let pe = WindowsPEInfo.read(executable),
              !onDemandAttempted.contains(executable.path) else { return false }
        let needed = MainActor.assumeIsolated { WindowsInstallerEnvironment.missing(WindowsRequirements.of(pe)) }
        guard !needed.isEmpty else { return false }
        onDemandAttempted.insert(executable.path)
        AppLog.record("[installer] \(executable.lastPathComponent) needs \(needed)")
        onDemandInstallTask = Task { @MainActor [weak self] in
            let failures = await WindowsInstallerEnvironment.install(needed) { [weak self] message in
                self?.setWindowsStatus(message)
            }
            self?.onDemandInstallTask = nil
            if !failures.isEmpty { self?.setWindowsStatus(failures.joined(separator: "\n")) }
            resume()
        }
        return true
    }

    /// Set once per app run, so a failed package does not block every launch.
    private var legacyVisualCRuntimeAttempted = false
    private var legacyVisualCRuntimeTask: Task<Void, Never>?
    private var legacyVisualCRuntimeGeneration = UUID()

    private func beginLegacyVisualCRuntimeInstallation(documents: URL, resume: @escaping () -> Void) {
        legacyVisualCRuntimeAttempted = true
        setWindowsStatus(VisualCRuntimeLegacy.installStatus)
        let generation = UUID()
        legacyVisualCRuntimeGeneration = generation
        legacyVisualCRuntimeTask = Task { @MainActor [weak self] in
            let failures = await VisualCRuntimeLegacy.installAll(documents: documents) { name in
                AppLog.record("[vcrt] installing Visual C++ \(name)")
            }
            guard let self, self.legacyVisualCRuntimeGeneration == generation else { return }
            self.legacyVisualCRuntimeTask = nil
            guard self.windowsStatus == VisualCRuntimeLegacy.installStatus else { return }
            for failure in failures { AppLog.record("[vcrt] \(failure)") }
            AppLog.record(failures.isEmpty ? "[vcrt] Visual C++ 2005-2013 and 32-bit runtimes installed"
                                           : "[vcrt] \(failures.count) Visual C++ packages failed; retried next launch")
            if self.windowsStatus == VisualCRuntimeLegacy.installStatus { self.setWindowsStatus("Windows Ready") }
            resume()
        }
    }

    private func beginVisualCRuntimeInstallation(prefix: URL, resume: @escaping () -> Void) {
        guard !ideck_wineprocess_running() else {
            setWindowsStatus("Visual C++ setup cannot start while another Wine session is running.")
            return
        }
        setWindowsStatus(VisualCRuntimeBootstrap.installStatus)
        VisualCRuntimeBootstrap.download(in: prefix) { [weak self] result in
            guard let self, self.windowsStatus == VisualCRuntimeBootstrap.installStatus else { return }
            switch result {
            case .failure(let error):
                self.setWindowsStatus("Visual C++ setup download failed: \(error.localizedDescription)")
            case .success(let installer):
                guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                               in: .userDomainMask).first else {
                    self.setWindowsStatus("Visual C++ extraction failed: Documents folder unavailable.")
                    return
                }
                VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: documents) { [weak self] result in
                    try? FileManager.default.removeItem(at: installer)
                    guard let self, self.windowsStatus == VisualCRuntimeBootstrap.installStatus else { return }
                    switch result {
                    case .success:
                        self.setWindowsStatus("Windows Ready")
                        resume()
                    case .failure(let error):
                        self.setWindowsStatus("Visual C++ extraction failed: \(error.localizedDescription)")
                    }
                }
            }
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
            self.launchWindowsExecutable(at: plan.executable, profile: launch)
        }
    }

    func launchWindowsExecutable(at url: URL, profile: WindowsGameProfile? = nil) {
        guard !isClosingWindowsSession else { return }
        isSteamSession = false
        let gameID = profile?.id ?? ""
        // The EA app's environment (EALibrary.prepareLaunch) belongs to EA games only.
        if !gameID.hasPrefix("ea:") { EALibrary.clearEnvironment() }
        // The Galaxy service belongs to the GOG game it was prepared for.
        if !gameID.hasPrefix("gog:") { DispatchQueue.main.async { MainActor.assumeIsolated { GOGGalaxy.shared.stop() } } }
        let launcher = gameID.hasPrefix("epic:") ? "Epic Games" : gameID.hasPrefix("ea:") ? "EA app"
            : gameID.hasPrefix("gog:") || gameID.hasPrefix("gog-setup:") ? "GOG" : ".exe"
        recordGameContext(profile?.title ?? url.deletingPathExtension().lastPathComponent, launcher: launcher)
        BenchmarkSession.begin(kind: "game", scenario: profile?.title ?? url.deletingPathExtension().lastPathComponent,
                               settings: BenchmarkSession.gameSettings(profile))
        guard !previousWineSessionStillFinishing() else { return }
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
                        self?.launchWindowsExecutable(at: destination, profile: profile)
                    }) { return }
                    self.jitResume = { [weak self] in self?.launchWindowsExecutable(at: destination, profile: profile) }
                    guard self.ensureJITForGameLaunch() else { return }
                    self.windowsEnvironment.configureWine(prefix: mountPath)
                    self.mountExternalDrives(prefix: mountPath)
                    let effectiveProfile = profile ?? WindowsGameProfile(id: destination.path, title: destination.deletingPathExtension().lastPathComponent)
                    self.windowsEnvironment.applyGameProfile(effectiveProfile)
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
        let skipSteamClient = skipSteamClient || Self.directSteamLaunchAppIDs.contains(game.appID)
        guard !isClosingWindowsSession else { return }
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
                    try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { message in
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
            setWindowsStatus("Execution Error: \(why). Restart iDeck before starting another game: swipe iDeck away in the app switcher, then open it again through StikDebug.")
            SteamLog.event("[wine-session] launch refused, restart needed: \(why)")
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
        legacyVisualCRuntimeGeneration = UUID()
        if let task = legacyVisualCRuntimeTask {
            task.cancel()
            legacyVisualCRuntimeTask = nil
            legacyVisualCRuntimeAttempted = false
        }
        isClosingWindowsSession = true
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
            windowsCloseWarning = "The Windows game has not exited. iDeck cannot safely force-kill an in-process Wine thread without risking an app crash. Try closing the game from its menu or retry Alt+F4."
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
        activeSteamGameID = nil
        activeSteamPrefix = nil
        pendingSteamGameID = nil
        activeWindowsProfile = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { GOGGalaxy.shared.stop() } }
        isClosingWindowsSession = false
        windowsCloseRequestedAt = nil
        windowsCloseWarning = nil
        windowsCloseWarningWasShown = false
        windowsStatusBeforeClose = nil
        SteamLog.event("[wine-close] Wine and wineserver exited; returning to Steam library")
        setWindowsStatus("Windows Ready")
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
                setWindowsStatus("Steam: " + failure)
                return
            }
        }
        let outcome = wineExitResult()
        let hostTrap = outcome.ntstatus == 0xC000001D
            && IllegalInstructionOrigin.isHost(logURL: Self.wineLogURL, since: wineLogStartOffset)
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
        SteamLog.event("[wine-exit] \(reason)")
        if ntstatus != 0 { Self.restartReason = "the last game crashed (NTSTATUS 0x\(String(ntstatus, radix: 16, uppercase: true)))" }
        setWindowsStatus(reason)
    }

    /// Why the next game needs a fresh iDeck process, or nil. Wine runs inside iDeck:
    /// after a crashed session, on a shrunken JIT pool or with little memory left, a
    /// second game started in the same process failed (BioShock after Dragon Age:
    /// 6108 MB in use, a 336 MB pool, a crash inside the runtime).
    static var restartReason: String?
    static let restartMinimumFreeMiB = 1500

    static func restartNeeded() -> String? {
        if let restartReason { return restartReason }
        if StikJITHelper.smallPoolMB > 0 { return "the JIT pool shrank to \(StikJITHelper.smallPoolMB) MB" }
        let free = ResourceGovernor.availableMiB()
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
