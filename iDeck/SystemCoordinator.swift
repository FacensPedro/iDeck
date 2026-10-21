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
        currentStatus =
