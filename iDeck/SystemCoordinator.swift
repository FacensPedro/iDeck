import Foundation
import Combine

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
    
    private let jitEnabler = JITEnabler()
    private let containerHost = ContainerHost()
    private let windowsEnvironment = WindowsEnvironment()
    
    func initializeSystem() {
        currentStatus = "Activating JIT..."
        jitEnabler.activate { [weak self] success in
            guard let self = self, success else {
                self?.currentStatus = "JIT Activation Failed"
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
    
    func launchSteam() {
        guard isJITEnabled && isContainerReady else { return }
        
        currentStatus = "Downloading Steam..."
        
        containerHost.mountEnvironment { [weak self] mountPath in
            self?.windowsEnvironment.configureWine(prefix: mountPath)
            self?.windowsEnvironment.installAndRunSteam { result in
                self?.currentStatus = result ? "Running Steam" : "Steam Error"
            }
        }
    }
    
    func launchWindowsExecutable(at url: URL) {
        guard isJITEnabled && isContainerReady else { return }
        
        currentStatus = "Loading Windows Environment..."
        
        containerHost.mountEnvironment { [weak self] mountPath in
            self?.windowsEnvironment.configureWine(prefix: mountPath)
            self?.windowsEnvironment.execute(binary: url) { result in
                self?.currentStatus = result ? "Running" : "Execution Error"
            }
        }
    }
}
