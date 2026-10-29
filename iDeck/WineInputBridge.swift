import SwiftUI
import GameController

final class WineInputBridge {
    static let shared = WineInputBridge()

    func startBridging() {
        ideck_controller_start()
    }

    func stopBridging() {
        // Native lifecycle cleanup is performed after Wine and wineserver
        // actually exit. The controller discovery bridge may now be stopped.
        ideck_controller_stop()
    }
}

struct WineGamepadEventClaim: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.handlesGameControllerEvents(matching: .gamepad)
        } else {
            content
        }
    }
}
