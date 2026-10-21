import Foundation
import Combine
import UIKit
import QuartzCore

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
    @Published var isVPNJITEnabled: Bool = false
    @Published var isAMFIBypassEnabled: Bool = true
    @Published var isGuestHooksEnabled: Bool = true
    
    @Published var isMaxRefreshRateEnabled: Bool = false {
        didSet {
            applyMaxRefreshRate()
        }
    }
    
    private let jitEnabler = JITEnabler()
    private let containerHost = ContainerHost()
    private let windowsEnvironment = WindowsEnvironment()
    private var displayLink: CADisplayLink?
    
    func startLiveContainer() {
        currentStatus = "Initializing LiveContainer..."
        containerHost.setupContainer(bypassAMFI: isAMFIBypassEnabled, injectHooks: isGuestHooksEnabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isContainerReady = success
                self?.currentStatus = success ? "LiveContainer Running" : "Container Error"
            }
        }
    }
    
    func startWindows() {
        guard isJITEnabled && isContainerReady else {
            currentStatus = "Requires JIT & LiveContainer"
            return
        }
        
        currentStatus = "Booting Windows Environment..."
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.currentStatus = "Windows Ready"
        }
    }
    
    func activateJITManually() {
        currentStatus = "Activating JIT..."
        jitEnabler.activate(for: getpid(), useVPN: isVPNJITEnabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isJITEnabled = success
                self?.currentStatus = success ? "JIT Activated" : "JIT Failed"
            }
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
                let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
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
