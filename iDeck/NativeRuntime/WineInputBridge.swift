import SwiftUI
import GameController

final class WineInputBridge {
    static let shared = WineInputBridge()

    func startBridging() {
        ideck_controller_start()
    }

    func stopBridging() {
        // Stop wireless discovery on view dismissal without unplugging
        // devices still assigned to the in-process Wine guest.
        ideck_controller_stop_discovery()
        // The SwiftUI session view can disappear on rotation, navigation
        // or backgrounding while the guest and its wineserver still run.
        // controller_stop also removes native XInput/HID devices; only the
        // completed runtime session may perform that cleanup.
        guard !ideck_wineprocess_running(),
              !ideck_wineserver_running(),
              ideck_wineprocess_thread_finished() else { return }
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
