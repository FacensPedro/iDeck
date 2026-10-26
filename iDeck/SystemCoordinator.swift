import Foundation
import Combine
import UIKit
import QuartzCore
import Darwin

class SystemCoordinator: ObservableObject {
    @Published var isJITEnabled: Bool = false
    @Published var isContainerReady: Bool = false
    @Published var currentStatus: String = "Ready"
    @Published var windowsStatus: String = "Ready"
    @Published var liveContainerStatus: String = "Ready"
    @Published var isSteamConnected: Bool = false
    
    @Published var isHUDEnabled: Bool = false {
        didSet {
            windowsEnvironment.graphicsConfig.isHUDEnabled = isHUDEnabled
            windowsEnvironment.graphicsConfig.applyGraphicsEnvironment()
        }
    }
    
    @Published var isMetalFXEnabled: Bool = UserDefaults.standard.bool(forKey: "metalFXEnabled") {
        didSet {
            UserDefaults.standard.set(isMetalFXEnabled, forKey: "metalFXEnabled")
            if isMetalFXEnabled {
                setenv("MVK_CONFIG_USE_METALFX", "1", 1)
            } else {
                unsetenv("MVK_CONFIG_USE_METALFX")
            }
        }
    }
    
    @Published var isD3DMetalEnabled: Bool = false {
        didSet {
            windowsEnvironment.graphicsConfig.useD3DMetal = isD3DMetalEnabled
            windowsEnvironment.graphicsConfig.applyGraphicsEnvironment()
        }
    }
    
    @Published var isJITPoolEnabled: Bool = false
    /// Starts the LocalDevVPN extension before activating JIT. Off by default: the extension needs
    /// a provisioning profile with the Network Extensions capability, and the helper-server
    /// flow does not need it.
    @Published var isVPNJITEnabled: Bool = false
    @Published var hasPairingFile: Bool = false
    @Published var isGuestHooksEnabled: Bool = true
    
    @Published var isMaxRefreshRateEnabled: Bool = false {
        didSet {
            applyMaxRefreshRate()
        }
    }
    
    let jitEnabler = JITEnabler()
    let containerHost = ContainerHost()
    let windowsEnvironment = WindowsEnvironment()
    let prefixInstaller = PrefixInstaller()
    private var displayLink: CADisplayLink?
    private var steamSignInObserver: NSObjectProtocol?

    init() {
        if isMetalFXEnabled { setenv("MVK_CONFIG_USE_METALFX", "1", 1) }
        refreshJITStatus()
        isSteamConnected = SteamSignIn.isSignedIn
        steamSignInObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSteamConnected = SteamSignIn.isSignedIn
        }
    }
    
    private func isLocalDevVPNActive() -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        
        var current = interfaces
        while let interface = current {
            let name = String(cString: interface.pointee.ifa_name)
            let isTunnel = name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("ipsec")
            // System utun interfaces only carry IPv6 link-local addresses; a VPN with an
            // IPv4 address on a tunnel interface is what the JIT bridge needs.
            if isTunnel, let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0 {
                return true
            }
            current = interface.pointee.ifa_next
        }
        return false
    }
    
    func setWindowsStatus(_ status: String) {
        let update = {
            self.windowsStatus = status
            self.currentStatus = status
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func setLiveContainerStatus(_ status: String) {
        let update = {
            self.liveContainerStatus = status
            self.currentStatus = status
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func refreshJITStatus() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let debuggerAttached = result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
        // StikDebug may detach after granting process JIT permission.
        // CS_DEBUGGED survives debugger detach; another MAP_JIT allocation can
        // fail while FEX already owns its JIT region. Probe only as a fallback.
        let pageSize = Int(getpagesize())
        let processPermission = ideck_process_has_jit_permission()
        let mapping = (processPermission || debuggerAttached) ? MAP_FAILED : mmap(nil, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0)
        let executableJIT = mapping != MAP_FAILED
        if executableJIT { _ = munmap(mapping, pageSize) }
        let detected = processPermission || debuggerAttached || executableJIT
        let update = {
            self.isJITEnabled = detected
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

    func forceJITAndStartLiveContainer() {
        refreshJITStatus()
        guard isJITEnabled else {
            setLiveContainerStatus("Activate JIT with StikDebug, then confirm it in iDeck Settings.")
            return
        }
        startLiveContainer()
    }

    func forceJITAndStartWindows() {
        refreshJITStatus()
        startWindows()
    }
    
    private func startLiveContainer() {
        setLiveContainerStatus("Initializing LiveContainer...")
        containerHost.setupContainer(injectHooks: isGuestHooksEnabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isContainerReady = success
                self?.setLiveContainerStatus(success ? "LiveContainer Running" : "Container Error")
            }
        }
    }
    
    private func startWindows() {
        setWindowsStatus("Preparing Windows Environment...")
        containerHost.setupContainer(injectHooks: isGuestHooksEnabled) { [weak self] setupSuccess in
            guard let self else { return }
            guard setupSuccess else {
                self.setWindowsStatus("Container initialization failed")
                return
            }

            self.containerHost.mountEnvironment { [weak self] mountPath in
                guard let self else { return }
                guard let mountPath else {
                    self.setWindowsStatus("Container not initialized")
                    return
                }

                DispatchQueue.main.async {
                    self.isContainerReady = true
                    guard Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil else {
                        self.setWindowsStatus("Library Ready — Madeira native runtime is not bundled")
                        return
                    }
                    self.setWindowsStatus("Preparing Wine prefix...")
                    self.prefixInstaller.installWinePrefix(to: mountPath) { success in
                        guard success else {
                            self.setWindowsStatus("Wine prefix setup failed")
                            return
                        }
                        self.windowsEnvironment.configureWine(prefix: mountPath)
                        self.setWindowsStatus(self.windowsEnvironment.hasRuntime(in: mountPath)
                            ? "Windows Runtime Ready" : "Madeira runtime components are missing")
                    }
                }
            }
        }
    }

    func requestStikDebugJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            setWindowsStatus("Cannot request JIT: missing iDeck bundle identifier.")
            return
        }
        // iOS does not expose SecTaskCreateFromSelf through the public Swift SDK.
        // StikDebug validates the target's get-task-allow entitlement when
        // attaching. A URL request must not be mistaken for JIT authorization.
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid()))
        ]
        // iPadOS 27 on A17 Pro requires a debugger-side breakpoint script.
        // The bundled Madeira JIT uses the universal BRK #0xf00d protocol.
        if #available(iOS 26.0, *) {
            components.queryItems?.append(
                URLQueryItem(name: "script-name", value: "universal.js")
            )
        }
        guard let url = components.url else {
            setWindowsStatus("Cannot create StikDebug request.")
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard let self else { return }
            self.setWindowsStatus(opened
                ? "StikDebug requested. Return to iDeck after JIT is enabled; FEX must still prepare its executable memory."
                : "StikDebug could not be opened. Install and configure StikDebug first.")
        }
    }

    func confirmJITActivatedByStikDebug() {
        refreshJITStatus()
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
    
    /// The JIT server mounts the Developer Disk Image itself; the picked files are not uploaded.
    func mountDDI(urls: [URL]) {
        currentStatus = "Mounting DDI..."
        jitEnabler.mountDeveloperDiskImage { [weak self] success in
            self?.currentStatus = success ? "DDI Mounted" : "DDI Mount Failed"
        }
    }
    
    private func applyMaxRefreshRate() {
        if isMaxRefreshRateEnabled {
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
        guard isJITEnabled && isContainerReady else { return }
        guard ideck_fex_jit_ready() else {
            setWindowsStatus("Cannot launch: StikDebug must remain attached to iDeck with the Madeira JIT script until FEX memory is prepared.")
            return
        }

        setWindowsStatus("Downloading Steam...")
        containerHost.mountEnvironment { [weak self] mountPath in
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
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.windowsEnvironment.applyGameProfile(WindowsGameProfile(id: "steam", title: "Steam"))
            self.windowsEnvironment.installAndRunSteam(jitEnabler: self.jitEnabler) { result in
                DispatchQueue.main.async {
                    self.setWindowsStatus(result ? "Steam Running" : "Steam Error")
                }
            }
        }
    }
    
    func launchWindowsExecutable(at url: URL, profile: WindowsGameProfile? = nil) {
        guard isContainerReady else { return }
        refreshJITStatus()

        guard url.pathExtension.lowercased() == "exe" else {
            setWindowsStatus("Choose a Windows .exe executable.")
            return
        }

        setWindowsStatus("Preparing executable...")
        let fileManager = FileManager.default
        let hasScope = url.startAccessingSecurityScopedResource()

        containerHost.mountEnvironment { [weak self] mountPath in
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
                let isAlreadyInLibrary = source.deletingLastPathComponent() == downloadDirectory
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

                guard self.isJITEnabled else {
                    self.setWindowsStatus("Executable is in the library. Enable JIT in Settings before launching.")
                    return
                }
                guard ideck_fex_jit_ready() else {
                    self.setWindowsStatus("Executable imported. JIT permission is present but StikDebug is no longer attached. Attach it to iDeck with the Madeira JIT script and retry.")
                    return
                }

                let launchPrepared: () -> Void = { [weak self] in
                    guard let self else { return }
                    guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                        let missing = self.windowsEnvironment.missingRuntimeComponents(in: mountPath)
                        self.setWindowsStatus("Madeira runtime missing: " + missing.joined(separator: ", "))
                        return
                    }
                    self.windowsEnvironment.configureWine(prefix: mountPath)
                    var effectiveProfile = profile ?? WindowsGameProfile(id: destination.path, title: destination.deletingPathExtension().lastPathComponent)
                    if self.isMetalFXEnabled { effectiveProfile.metalFXEnabled = true }
                    self.windowsEnvironment.applyGameProfile(effectiveProfile)
                    self.windowsEnvironment.execute(
                        binary: destination,
                        arguments: profile?.arguments ?? "",
                        is32Bit: false,
                        isSteam: false,
                        jitEnabler: self.jitEnabler
                    ) { result in
                        DispatchQueue.main.async {
                            self.setWindowsStatus(result ? "Running" : "Execution Error: Windows runtime failed to start")
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
    func launchSteamGame(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
        refreshJITStatus()
        guard isJITEnabled else {
            setWindowsStatus("Cannot launch: activate JIT in StikDebug first.")
            return
        }
        guard ideck_fex_jit_ready() else {
            setWindowsStatus("Cannot launch: StikDebug must remain attached to iDeck with the Madeira JIT script until the FEX pool is ready.")
            return
        }

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

        windowsEnvironment.configureWine(prefix: prefixPath.path)
        var effectiveProfile = profile
        if isMetalFXEnabled { effectiveProfile.metalFXEnabled = true }
        windowsEnvironment.applyGameProfile(effectiveProfile)
        setWindowsStatus("Launching Steam game...")
        windowsEnvironment.execute(binary: executableURL,
                                   arguments: profile.arguments.isEmpty ? entryArguments : profile.arguments,
                                   jitEnabler: jitEnabler) { [weak self] success in
            DispatchQueue.main.async {
                self?.setWindowsStatus(success ? "Running" : "Execution Error: Windows game launch failed")
            }
        }
    }

    private func steamExecutable(game: SteamAppInfo, directory: URL) -> (url: URL, arguments: String)? {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL

        func verified(_ relative: String) -> URL? {
            var folded: [String: String] = [:]
            guard let path = SteamInstallFiles.safeRelativePath(relative, folded: &folded),
                  path.lowercased().hasSuffix(".exe") else { return nil }
            let file = root.appendingPathComponent(path)
                .resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return file
        }

        for option in game.launches where
            (option.oslist.isEmpty || option.oslist.lowercased().contains("windows")) &&
            (option.requiredDLC?.isEmpty != false) {
            if let executable = verified(option.executable) {
                return (executable, option.arguments)
            }
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
        return (best.url, "")
    }

    /// Loads and starts a guest .app inside this process (see LiveContainerHook).
    func launchGuestApp(at url: URL) {
        guard isJITEnabled && isContainerReady else {
            setLiveContainerStatus("Requires JIT & LiveContainer")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            setLiveContainerStatus("Guest app not found")
            return
        }
        
        setLiveContainerStatus("Launching: \(url.lastPathComponent)")
        var message: NSString?
        if LiveContainerHook.launchGuestApp(atPath: url.path, errorMessage: &message) {
            setLiveContainerStatus("Guest app running: \(url.lastPathComponent)")
        } else {
            setLiveContainerStatus("Guest launch failed: \(message ?? "O carregador não conseguiu abrir este aplicativo.")")
        }
    }
}
