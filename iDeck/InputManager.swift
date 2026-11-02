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
        // Wine's native XInput/HID bridge only accepts extended gamepads.
        // Do not show a remote or micro-gamepad as supported when it has no
        // matching virtual Windows controller slot.
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }
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
