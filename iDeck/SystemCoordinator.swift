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
    
    @Published var isMetalFXEnabled: Bool = false {
        didSet {
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
        let update = {
            self.isJITEnabled = debuggerAttached
            if !debuggerAttached && (self.currentStatus == "JIT confirmed via StikDebug" || self.currentStatus == "Ready") {
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

                self.prefixInstaller.installWinePrefix(to: mountPath) { success in
                    DispatchQueue.main.async {
                        if success {
                            self.isContainerReady = true
                            self.windowsEnvironment.configureWine(prefix: mountPath)
                            self.setWindowsStatus(self.windowsEnvironment.hasRuntime(in: mountPath) ? "Windows Runtime Ready" : "Library Ready — Madeira native runtime is not bundled")
                        } else {
                            self.setWindowsStatus("Failed to Install Windows Environment")
                        }
                    }
                }
            }
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
                let downloads = root.appendingPathComponent("WindowsDownloads", isDirectory: true)
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

                guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                    self.setWindowsStatus("Madeira runtime missing: the in-process FEX/Wine/DXMT runtime has not been installed in this build.")
                    return
                }

                self.windowsEnvironment.configureWine(prefix: mountPath)
                if let profile {
                    self.windowsEnvironment.applyGameProfile(profile)
                }
                self.windowsEnvironment.execute(
                    binary: destination,
                    arguments: profile?.arguments ?? "",
                    is32Bit: false,
                    isSteam: false,
                    jitEnabler: self.jitEnabler
                ) { result in
                    DispatchQueue.main.async {
                        self.setWindowsStatus(result ? "Running" : "Execution Error: the configured Windows runtime failed to start")
                    }
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

        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        guard SteamInstallFiles.buildID(appID: Int(game.appID), steamApps: steamApps) != nil else {
            setWindowsStatus("Cannot launch: this Steam game is not installed.")
            return
        }

        guard let entry = game.launches.first(where: { option in
            (option.oslist.isEmpty || option.oslist.lowercased().contains("windows")) &&
            option.requiredDLC == nil && option.executable.lowercased().hasSuffix(".exe")
        }) else {
            setWindowsStatus("Cannot launch: Steam did not provide a Windows executable for this game.")
            return
        }

        var folded: [String: String] = [:]
        guard let relativePath = SteamInstallFiles.safeRelativePath(entry.executable, folded: &folded),
              relativePath.lowercased().hasSuffix(".exe") else {
            setWindowsStatus("Cannot launch: invalid Steam executable path.")
            return
        }

        let directory = SteamInstallPaths.common(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
            .appendingPathComponent(SteamInstallFiles.safeFolderName(game.installDir), isDirectory: true)
        let executableURL = directory.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExecutable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedExecutable.path.hasPrefix(resolvedRoot.path + "/"),
              FileManager.default.fileExists(atPath: resolvedExecutable.path) else {
            setWindowsStatus("Cannot launch: the Windows executable is missing.")
            return
        }
        guard windowsEnvironment.hasRuntime(in: prefixPath.path) else {
            setWindowsStatus("Madeira runtime missing: FEX/Wine/DXMT must be installed and linked.")
            return
        }

        windowsEnvironment.configureWine(prefix: prefixPath.path)
        windowsEnvironment.applyGameProfile(profile)
        setWindowsStatus("Launching Steam game...")
        windowsEnvironment.execute(binary: executableURL,
                                   arguments: profile.arguments.isEmpty ? entry.arguments : profile.arguments,
                                   jitEnabler: jitEnabler) { [weak self] success in
            DispatchQueue.main.async {
                self?.setWindowsStatus(success ? "Running" : "Execution Error: Windows game launch failed")
            }
        }
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
            setLiveContainerStatus("Guest launch failed: \(message ?? "unknown error")")
        }
    }
}
