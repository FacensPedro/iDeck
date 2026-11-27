// SystemCoordinator: Madeira Dock sessions.
// Split from SystemCoordinator.swift (iDeck 3.0 architecture).

import Foundation
import Darwin

extension SystemCoordinator {
    /// Prepares Wine's JIT pool before a Steam client session and checks it is
    /// large enough. The components download can outlast StikDebug's
    /// attachment, so this runs again right before the client starts.
    func launchThroughDock(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
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
    func finishSteamPrerequisiteSession() -> Bool {
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
}
