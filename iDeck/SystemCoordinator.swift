import Foundation
import Combine
import UIKit
import QuartzCore
import Darwin

class SystemCoordinator: ObservableObject {
    @Published var isJITEnabled: Bool = false
    @Published var isContainerReady: Bool = false
    @Published var currentStatus: String = "Ready"
    
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
            currentStatus = "Activate JIT with StikDebug, then confirm it in iDeck Settings."
            return
        }
        startLiveContainer()
    }

    func forceJITAndStartWindows() {
        refreshJITStatus()
        startWindows()
    }
    
    private func startLiveContainer() {
        currentStatus = "Initializing LiveContainer..."
        containerHost.setupContainer(injectHooks: isGuestHooksEnabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isContainerReady = success
                self?.currentStatus = success ? "LiveContainer Running" : "Container Error"
            }
        }
    }
    
    private func startWindows() {
        currentStatus = "Preparing Windows Environment..."
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            guard let mountPath = mountPath else {
                self.currentStatus = "Container not initialized"
                return
            }
            
            self.prefixInstaller.installWinePrefix(to: mountPath) { success in
                DispatchQueue.main.async {
                    if success {
                        self.isContainerReady = true
                        self.windowsEnvironment.configureWine(prefix: mountPath)
                        self.currentStatus = "Windows Ready"
                    } else {
                        self.currentStatus = "Failed to Install Windows Environment"
                    }
                }
            }
        }
    }
    
    func confirmJITActivatedByStikDebug() {
        refreshJITStatus()
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
        
        currentStatus = "Downloading Steam..."
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            guard let mountPath = mountPath else {
                self.currentStatus = "Container not initialized"
                return
            }
            guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                DispatchQueue.main.async {
                    self.currentStatus = "Madeira runtime missing: FEX/box64 and Wine ARM64EC are not installed."
                }
                return
            }
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.windowsEnvironment.installAndRunSteam(jitEnabler: self.jitEnabler) { result in
                DispatchQueue.main.async {
                    self.currentStatus = result ? "Steam Running" : "Steam Error"
                }
            }
        }
    }
    
    func launchWindowsExecutable(at url: URL) {
        guard isContainerReady else { return }
        
        refreshJITStatus()
        currentStatus = "Importing Executable..."
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            guard let mountPath = mountPath else {
                self.currentStatus = "Container initialization failed"
                return
            }
            do {
                let downloads = URL(fileURLWithPath: mountPath).appendingPathComponent("WindowsDownloads", isDirectory: true)
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let destination = downloads.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                guard self.isJITEnabled else {
                    DispatchQueue.main.async {
                        self.currentStatus = "Executable imported. Enable JIT for iDeck in StikDebug before running it."
                    }
                    return
                }
                guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                    DispatchQueue.main.async {
                        self.currentStatus = "Madeira runtime missing: FEX/box64 and Wine ARM64EC are not installed."
                    }
                    return
                }
                self.windowsEnvironment.configureWine(prefix: mountPath)
                self.windowsEnvironment.execute(binary: destination, is32Bit: false, isSteam: false, jitEnabler: self.jitEnabler) { result in
                    DispatchQueue.main.async {
                        self.currentStatus = result ? "Running" : "Execution Error: Madeira Wine/FEX runtime is missing or failed to start"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.currentStatus = "Executable import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads and starts a guest .app inside this process (see LiveContainerHook).
    func launchGuestApp(at url: URL) {
        guard isJITEnabled && isContainerReady else {
            currentStatus = "Requires JIT & LiveContainer"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            currentStatus = "Guest app not found"
            return
        }
        
        currentStatus = "Launching: \(url.lastPathComponent)"
        var message: NSString?
        if LiveContainerHook.launchGuestApp(atPath: url.path, errorMessage: &message) {
            currentStatus = "Guest app running: \(url.lastPathComponent)"
        } else {
            currentStatus = "Guest launch failed: \(message ?? "unknown error")"
        }
    }
}
