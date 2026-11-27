// SystemCoordinator: JIT (StikDebug, built-in helper, pairing file).
// Split from SystemCoordinator.swift (iDeck 3.0 architecture).

import Foundation
import UIKit
import Darwin

extension SystemCoordinator {
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
    func cancelQueuedLaunches() {
        launchGeneration &+= 1
        pendingJITLaunch = nil
        jitResume = nil
    }

    /// Madeira's readiness: StikJITHelper.ready (CS_DEBUGGED and a live
    /// debugger) or a pool already exported. The pool itself is allocated at
    /// launch (MadeiraWinePool), followed by Madeira's early detach.
    @discardableResult
    func ensureJITForGameLaunch() -> Bool {
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

    static func jitPreparationValidated() -> Bool {
        guard ideck_process_has_jit_permission() else { return false }
        return ideck_wine_jit_pool_ready() || StikJITHelper.ready
    }

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
                    if !response.success {
                        // "Timed out connecting to <ip>:49152": the device's own lockdown
                        // port is reached through the loopback VPN, so that VPN is off.
                        // Try again a few times (it may be coming up), then say so plainly.
                        if response.message.contains("Timed out connecting") {
                            if Self.builtInVPNRetries < 3 {
                                Self.builtInVPNRetries += 1
                                AppLog.record("[jit-builtin] the loopback VPN did not answer; retry \(Self.builtInVPNRetries) of 3 in 3 s")
                                self.setWindowsStatus(tr("Connect to LocalDevVPN"))
                                self.builtInWait?.invalidate()
                                self.builtInWait = nil
                                self.jitRequestStartedAt = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.requestStikDebugJIT() }
                                return
                            }
                            Self.builtInVPNRetries = 0
                            self.builtInFailed(tr("Connect to LocalDevVPN"))
                            return
                        }
                        self.builtInFailed("Built-in JIT: " + response.message)
                    } else {
                        Self.builtInVPNRetries = 0
                    }
                case .failure(let error):
                    self.builtInFailed("Built-in JIT: " + error.localizedDescription)
                }
            }
        }
    }

    /// With the built-in JIT method, iDeck enables JIT by itself when it opens: once
    /// per process, when a pairing file is there, no JIT is active yet and no Windows
    /// program runs. Nothing to tap and no app switch, as with StikDebug's own opening.
    func autoEnableBuiltInJIT() {
        guard jitMethod == "builtIn", !Self.builtInAutoRequested,
              FileManager.default.fileExists(atPath: pairingFileURL.path),
              !ideck_wineprocess_running(), MadeiraBundleIdentity.isNative else { return }
        refreshJITStatus()
        guard !isJITEnabled, !Self.jitPreparationValidated() else { return }
        Self.builtInAutoRequested = true
        AppLog.record("[jit-builtin] enabling JIT by itself at iDeck's start")
        requestStikDebugJIT()
    }

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
}
