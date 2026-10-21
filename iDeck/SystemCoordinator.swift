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
    @Published var isVPNJITEnabled: Bool = true
    @Published var isAMFIBypassEnabled: Bool = true
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
            if name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("ipsec") {
                return true
            }
            current = interface.pointee.ifa_next
        }
        return false
    }
    
    func forceJITAndStartLiveContainer() {
        if isJITEnabled {
            startLiveContainer()
        } else {
            activateJITManually { success in
                if success {
                    self.startLiveContainer()
                }
            }
        }
    }
    
    func forceJITAndStartWindows() {
        if isJITEnabled {
            startWindows()
        } else {
            activateJITManually { success in
                if success {
                    self.startWindows()
                }
            }
        }
    }
    
    private func startLiveContainer() {
        currentStatus = "Initializing LiveContainer..."
        containerHost.setupContainer(bypassAMFI: isAMFIBypassEnabled, injectHooks: isGuestHooksEnabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isContainerReady = success
                self?.currentStatus = success ? "LiveContainer Running" : "Container Error"
            }
        }
    }
    
    private func startWindows() {
        guard isJITEnabled else {
            currentStatus = "Requires JIT"
            return
        }
        
        currentStatus = "Installing Windows Environment..."
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            
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
    
    func activateJITManually(completion: ((Bool) -> Void)? = nil) {
        let activateTask = {
            let fileManager = FileManager.default
            let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let pairingPath = documentDirectory.appendingPathComponent("pairing_file.mobiledevicepairing")
            
            let pairingURL = fileManager.fileExists(atPath: pairingPath.path) ? pairingPath : nil
            
            self.currentStatus = "Activating JIT..."
            self.jitEnabler.activate(for: getpid(), useVPN: self.isVPNJITEnabled, pairingFileURL: pairingURL) { [weak self] success in
                DispatchQueue.main.async {
                    self?.isJITEnabled = success
                    self?.currentStatus = success ? "JIT Activated" : "JIT Failed"
                    completion?(success)
                }
            }
        }
        
        if isVPNJITEnabled && !isLocalDevVPNActive() {
            currentStatus = "Starting LocalDevVPN..."
            VPNManager.shared.setupAndConnectLocalDevVPN { [weak self] success in
                if success {
                    activateTask()
                } else {
                    DispatchQueue.main.async {
                        self?.currentStatus = "Failed to start VPN"
                        completion?(false)
                    }
                }
            }
        } else {
            activateTask()
        }
    }
    
    func importPairingFile(at url: URL) {
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pairingPath = documentDirectory.appendingPathComponent("pairing_file.mobiledevicepairing")
        
        do {
            if fileManager.fileExists(atPath: pairingPath.path) {
                try fileManager.removeItem(at: pairingPath)
            }
            try fileManager.copyItem(at: url, to: pairingPath)
            currentStatus = "Pairing file imported"
        } catch {
            currentStatus = "Pairing import failed"
        }
    }
    
    func mountDDI(urls: [URL]) {
        currentStatus = "Mounting DDI..."
        jitEnabler.mountDeveloperDiskImage(urls: urls) { [weak self] success in
            DispatchQueue.main.async {
                self?.currentStatus = success ? "DDI Mounted" : "DDI Mount Failed"
            }
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
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.windowsEnvironment.installAndRunSteam(jitEnabler: self.jitEnabler) { result in
                DispatchQueue.main.async {
                    self.currentStatus = result ? "Steam Running" : "Steam Error"
                }
            }
        }
    }
    
    func launchWindowsExecutable(at url: URL) {
        guard isJITEnabled && isContainerReady else { return }
        
        currentStatus = "Loading Executable..."
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.windowsEnvironment.execute(binary: url, jitEnabler: self.jitEnabler) { result in
                DispatchQueue.main.async {
                    self.currentStatus = result ? "Running" : "Execution Error"
                }
            }
        }
    }
}
