// SystemCoordinator: launching programs and Steam games.
// Split from SystemCoordinator.swift (iDeck 3.0 architecture).

import Foundation
import UIKit
import Darwin

extension SystemCoordinator {
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

    func withPreparedMetalDisplay(expectedStatus: String, remainingChecks: Int = 300, perform: @escaping () -> Void) {
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

    func nativeLaunchFailure(_ status: Int) -> String {
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
