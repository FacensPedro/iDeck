import Foundation
import GameController

class InputManager: ObservableObject {
    @Published var isControllerConnected: Bool = false
    
    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnect), name: .GCControllerDidDisconnect, object: nil)
        GCController.startWirelessControllerDiscovery {}
    }
    
    @objc private func controllerDidConnect(notification: Notification) {
        isControllerConnected = true
    }
    
    @objc private func controllerDidDisconnect(notification: Notification) {
        isControllerConnected = false
    }
}
