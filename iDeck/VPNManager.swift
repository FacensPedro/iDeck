import Foundation
import NetworkExtension

class VPNManager {
    static let shared = VPNManager()
    
    func setupAndConnectLocalDevVPN(completion: @escaping (Bool) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let manager = managers?.first(where: { $0.localizedDescription == "LocalDevVPN" }) ?? NETunnelProviderManager()
            
            manager.localizedDescription = "LocalDevVPN"
            
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".VPNExtension"
            proto.serverAddress = "127.0.0.1"
            
            manager.protocolConfiguration = proto
            manager.isEnabled = true
            
            manager.saveToPreferences { error in
                guard error == nil else {
                    completion(false)
                    return
                }
                
                manager.loadFromPreferences { error in
                    do {
                        try manager.connection.startVPNTunnel()
                        completion(true)
                    } catch {
                        completion(false)
                    }
                }
            }
        }
    }
}
