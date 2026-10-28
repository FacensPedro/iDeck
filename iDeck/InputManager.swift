import Foundation
import GameController

final class InputManager: ObservableObject {
    static let shared = InputManager()

    @Published private(set) var isControllerConnected = false
    @Published private(set) var controllerName = "None"

    private init() {
        refreshControllers()
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConnectionChanged),
                                               name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConnectionChanged),
                                               name: .GCControllerDidDisconnect, object: nil)
        GCController.startWirelessControllerDiscovery {}
    }

    func refreshControllers() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refreshControllers() }
            return
        }
        let connected = GCController.controllers()
        let first = connected.first
        isControllerConnected = first != nil
        controllerName = first?.vendorName ?? "None"
    }

    @objc private func controllerConnectionChanged(_ notification: Notification) {
        refreshControllers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
