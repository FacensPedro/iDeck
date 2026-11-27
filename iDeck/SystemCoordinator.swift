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
    var activeSteamGameID: UInt32?
    /// A Madeira Dock (Steam client) session is running; its final report is
    /// read when Wine exits.
    var dockSessionActive = false
    // The Wine host can return 0 after a Steam-launched game child aborts.
    // Only inspect Wine fatal-crash lines written after the current launch.
    var wineLogStartOffset: Int64?
    /// The program the last launch prepared (prepareVisualCRuntimeIfNeeded), for what a
    /// session's log says about it afterwards.
    var lastPreparedExecutable: URL?

    static var wineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.txt", isDirectory: false)
    }

    /// madeira-log.txt grows by every session (Madeira opens it for appending) and was
    /// never cut. Between sessions, while no Wine runs, a log past this size is kept
    /// as madeira-log.previous.txt.lzfse (one kept: repeated lines folded, then
    /// compressed), so the current log stays small and fast to scan and copy.
    static let wineLogRotateBytes: Int64 = 8 << 20

    var activeSteamInstallerAppID: UInt32?
    var steamDockStartedAt: TimeInterval?
    @Published var steamPrerequisiteProgress: String?
    @Published var steamDockLaunchStage: String?
    @Published var currentSteamLaunchUsesDock = false
    @Published var dockLaunchAccepted = false
    /// Whether the current (or last) Wine session is a game installed by
    /// Steam. Errors that mention Steam are shown only for those sessions.
    /// Kept across launches so Bugs & logs can tell what the last run was.
    @Published var isSteamSession: Bool = UserDefaults.standard.bool(forKey: "session.lastWasSteam") {
        didSet { UserDefaults.standard.set(isSteamSession, forKey: "session.lastWasSteam") }
    }

    var memorySampler: Timer?
    var finishMemorySample: ((String, String?) -> Void)?

    @Published var activeWindowsProfile: WindowsGameProfile? {
        // The game the JIT pool is prepared for (MadeiraWinePool reads it to size the
        // pool from what GameCompatibility learned about this game).
        didSet {
            if let id = activeWindowsProfile?.id { setenv("IDECK_COMPAT_GAME", id, 1) }
            else if oldValue != nil { unsetenv("IDECK_COMPAT_GAME") }
        }
    }
    var activeSteamPrefix: String?
    var pendingSteamGameID: UInt32?
    @Published var isClosingWindowsSession = false
    @Published var windowsCloseWarning: String?
    var windowsCloseRequestedAt: TimeInterval?
    var windowsCloseWarningWasShown = false
    var windowsCloseAttempts = 0
    var windowsStatusBeforeClose: String?
    var wineJITPreparationInFlight = false
    var wineJITAttemptedDuringAttachment = false
    @Published var needsVisualCRuntimeConsent = false
    var visualCRuntimeConsentAction: (() -> Void)?
    var visualCRuntimeSkipAction: (() -> Void)?
    private var bypassVisualCRuntimeForPrefix: String?

    static let supportedWineJITPoolMiB: Set<Int> = [64, 96, 128, 192, 256, 384, 512, 560, 624, 640, 768, 896, 1152]

    /// The pool size that last prepared successfully on this device: the
    /// native side starts there instead of retrying larger sizes the
    /// debugger cannot allocate. Choosing a size in Settings resets it.
    /// v2: sizes saved before the early placeholder was released (#150)
    /// reflect the blocked layout, not the device, and are ignored.
    static let lastGoodPoolKey = "wineJITPoolLastGoodMiB.v2"

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
    var dockInstallAfterPrefix = false
    var isPreparingWindowsPrefix = false

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
        SessionLifecycle.shared.report(status: status)
        switch status {
        case "Wine started; waiting for game...":
            BenchmarkSession.mark("wine_started")
            ControllerAudioGuard.shared.recheck()
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

    /// Avoid repeated StikDebug prompts when CS_DEBUGGED is already enabled
    /// for this iDeck PID. Permission alone does not prepare Wine's RX pool:
    /// that still requires a live BRK-capable debugger, and a failed RX
    /// allocation must be surfaced rather than disguised as a JIT prompt.
    /// The launch to continue once StikDebug is attached (set by the caller
    /// right before `ensureJITForGameLaunch()`), as Madeira's jitReadyForLaunch(then:).
    var jitResume: (() -> Void)?
    private var jitWaitGeneration = 0

    /// The launch that continues when StikDebug reports the debugger attached
    /// (StikJITHelper.waitForDebugger), as Madeira's jitReadyForLaunch(then:).
    var pendingJITLaunch: (() -> Void)?
    /// Raised by every close: a launch queued behind JIT preparation before it is
    /// stale and never starts Wine into a session that is being torn down.
    var launchGeneration = 0
    var pendingJITLaunchGeneration = 0

    /// JIT is ready for a launch: CS_DEBUGGED is set and the pool is prepared or a
    /// debugger is attached to prepare it.
    /// The executable window kept free by the pool prepared at startup.
    static let earlyExeWindowMB = 192
    /// Set once that early pool exists: a game whose fixed-base exe needs more cannot
    /// load in this run (the pool cannot move without the debugger).
    static var earlyPoolExeWindowMB = 0

    static let lastLaunchJITKey = "jit.lastLaunchState"

    static let jitMethodKey = "jit.method"

    /// "builtIn" (iDeck's own helper through LocalDevVPN) or "stikdebug".
    var jitMethod: String {
        UserDefaults.standard.string(forKey: Self.jitMethodKey) ?? "stikdebug"
    }

    /// Retries of a built-in request whose loopback VPN did not answer.
    static var builtInVPNRetries = 0

    /// Whether this iDeck process already asked the built-in helper by itself.
    static var builtInAutoRequested = false

    /// The wait for the debugger that a built-in request started.
    var builtInWait: Timer?

    /// When the JIT request in flight was started (nil: none). A second request
    /// within 20 s joins it instead of opening StikDebug again.
    var jitRequestStartedAt: Date?
    /// Watches for iDeck coming back in front after StikDebug was opened.
    var jitHandoffObserver: NSObjectProtocol?

    var pairingFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pairing_file.mobiledevicepairing")
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
    
    

    /// Programs whose dependencies were already offered this run (a failed download
    /// does not block every launch).
    var onDemandAttempted = Set<String>()
    var bundledRuntimeChecked = false
    /// Program path -> size and modification date when its libraries were complete.
    var satisfiedExecutables: [String: String] = [:]

    var onDemandInstallTask: Task<Void, Never>?

    /// The store client whose installer is downloading, and its progress text.
    @Published var storeClientDownload: String?

    /// The EA app and Ubisoft Connect are installing (downloaded and copied on the device, without Wine).
    @Published var storeSetupInBackground = false
    /// Why the last background installation of the launchers failed.
    @Published var storeClientError: String?

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
    var sessionStartedAt: Date?
    /// When a Steam game was last started without Steam's client (SteamClientNeed).
    var directSteamStartedAt: Date?

    /// Set by launchWindowsProgram right before an installer starts; read once.
    var nextLaunchIsInstaller = false

    /// Launches a Steam game in its original installation directory, preserving
    /// relative DLL and asset paths instead of copying the executable elsewhere.
    /// Steam games that need no Steam client to run and fail when Valve's
    /// client spawns them. Empty since 2.16.2: Bully: Scholarship Edition (12200)
    /// was here because a 32-bit child of the Steam client once started without
    /// an emulator CPU area, which the CPU-area fix ended (Assassin's Creed IV
    /// runs as one). Its current build carries Steam's DRM, and started directly
    /// it stopped on "Steam Error: Application load error P:0000065434"
    /// (2026-11-25), so it goes through Valve's client like the other games.
    static let directSteamLaunchAppIDs: Set<UInt32> = []

    /// Starts an installed Steam game through Valve's own Windows client
    /// (Madeira Dock): Valve's client signs in, checks the licence and starts
    /// the game with its DRM untouched.
    /// Status shown on the game's loading screen while Steam's client
    /// components download before the first Steam game starts.
    static let steamComponentsInstallStatus = "Installing Steam client components..."

    /// Prepare Valve's verified client components before the first Steam
    /// game launch. Never silently fall back to the direct EXE: that would
    /// bypass the official launch path needed by licensed/DRM games.
    func installSteamComponentsThenLaunch(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
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

    // Wine is hosted in a thread of the iDeck process; native state may
    // remain live for some time after the guest's running flag becomes false.
    // Reject a new launch before any prefix/JIT/Metal preparation until the
    // pinned Wine worker and the in-app wineserver have both exited.
    /// Polls the native session release for up to `timeout` seconds. The pool
    /// and the previous session's image copies are only reused after this
    /// returns true (ideck_runtime_complete_session saw both threads stopped).
    func waitForSessionCleanup(timeout: TimeInterval = 5) -> Bool {
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

    /// Frees what a finished session held and iDeck rebuilds on demand: the GOG
    /// Galaxy service, Madeira Dock's leftovers, cached responses and artwork, and
    /// the Metal caches the governor owns. Safe to call more than once.
    /// When the session that is ending started: temporary files from before it are stale.
    var sessionTempCutoff = Date.distantPast

    /// Why the next game needs a fresh iDeck process, or nil. Wine runs inside iDeck:
    /// after a crashed session, on a shrunken JIT pool or with little memory left, a
    /// second game started in the same process failed (BioShock after Dragon Age:
    /// 6108 MB in use, a 336 MB pool, a crash inside the runtime).
    static var restartReason: String?
    static let restartMinimumFreeMiB = 1500

    static let cleanupStuckMessage = "Execution Error: the previous Windows session did not finish closing. Wine runs inside iDeck, so restart iDeck to start another game: swipe iDeck away in the app switcher, then open it again."
    static let restartMessage = "Execution Error: restart iDeck to start another game: swipe iDeck away in the app switcher, then open it again."

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
