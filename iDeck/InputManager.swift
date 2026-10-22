import Foundation
import GameController

class InputManager: ObservableObject {
    static let shared = InputManager()
    @Published var isControllerConnected: Bool = false
    @Published var controllerName: String = "None"
    
    private init() {
        isControllerConnected = !GCController.controllers().isEmpty
        controllerName = GCController.controllers().first?.vendorName ?? "None"
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnect), name: .GCControllerDidDisconnect, object: nil)
        GCController.startWirelessControllerDiscovery {}
    }
    
    @objc private func controllerDidConnect(notification: Notification) {
        isControllerConnected = true
        controllerName = (notification.object as? GCController)?.vendorName ?? "Controller"
    }
    
    @objc private func controllerDidDisconnect(notification: Notification) {
        isControllerConnected = !GCController.controllers().isEmpty
        controllerName = GCController.controllers().first?.vendorName ?? "None"
    }
}
