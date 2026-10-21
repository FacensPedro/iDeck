import Foundation
import Combine
import UIKit
import QuartzCore

class SystemCoordinator: ObservableObject {
    @Published var isJITEnabled: Bool = false
    @Published var isContainerReady: Bool = false
    @Published var currentStatus: String = "Idle"
    
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
    
    @Published var isJITPoolEnabled: Bool = false
    
    @Published var isMaxRefreshRateEnabled: Bool = false {
        didSet {
            applyMaxRefreshRate()
        }
    }
    
    private let jitEnabler = JITEnabler()
    private let containerHost = ContainerHost()
    private let windowsEnvironment = WindowsEnvironment()
    
    private var displayLink: CADisplayLink?
    
    func initializeSystem() {
        currentStatus = "Activating Host JIT..."
        jitEnabler.activate(for: getpid()) { [weak self] success in
            guard let self = self, success else {
                self?.currentStatus = "Host JIT Activation Failed"
                return
            }
            
            self.isJITEnabled = true
            self.currentStatus = "Initializing LiveContainer..."
            
            self.containerHost.setupContainer { containerSuccess in
                if containerSuccess {
                    self.isContainerReady = true
                    self.currentStatus = "System Ready"
                } else {
                    self.currentStatus = "Container Setup Failed"
                }
            }
        }
    }
    
    func activateJITManually() {
        currentStatus = "Activating JIT Manually..."
        jitEnabler.activate(for: getpid()) { [weak self] success in
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
            currentStatus = "Pairing file imported successfully"
        } catch {
            currentStatus = "Failed to import pairing file"
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
    
    @objc private func dummyDisplayLinkUpdate() {
        // Keeps the display at maximum refresh rate
    }
    
    func launchSteam() {
        guard isJITEnabled && isContainerReady else { return }
        
        currentStatus = "Downloading Steam..."
        
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.windowsEnvironment.installAndRunSteam(jitEnabler: self.jitEnabler) { result in
                DispatchQueue.main.async {
                    self.currentStatus = result ? "Running Steam" : "Steam Error"
                }
            }
        }
    }
    
    func launchWindowsExecutable(at url: URL) {
        guard isJITEnabled && isContainerReady else { return }
        
        currentStatus = "Loading Windows Environment..."
        
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
