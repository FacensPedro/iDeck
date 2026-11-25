import Foundation
import GameController

final class InputManager: ObservableObject {
    static let shared = InputManager()

    @Published private(set) var isControllerConnected = false
    @Published private(set) var controllerName = "None"
    @Published private(set) var connectedKind: Kind = .none

    /// The families iDeck tells apart, from GameController's own classes and category.
    enum Kind: Equatable {
        case none, dualSense, dualShock4, xboxSeries, xbox360, joyCon, joyCon2, switchPro, switch2Pro, other
        var isPlayStation: Bool { self == .dualSense || self == .dualShock4 }
        var isNintendo: Bool { [.joyCon, .joyCon2, .switchPro, .switch2Pro].contains(self) }
        var isXbox: Bool { self == .xboxSeries || self == .xbox360 }
        var label: String {
            switch self {
            case .none: return "None"
            case .dualSense: return "DualSense"
            case .dualShock4: return "DualShock 4"
            case .xboxSeries: return "Xbox One / Series"
            case .xbox360: return "Xbox 360"
            case .joyCon: return "Joy-Con"
            case .joyCon2: return "Joy-Con 2"
            case .switchPro: return "Nintendo Switch Pro Controller"
            case .switch2Pro: return "Nintendo Switch 2 Pro Controller"
            case .other: return "Controller"
            }
        }
    }

    static func kind(of controller: GCController) -> Kind {
        let name = ((controller.productCategory) + " " + (controller.vendorName ?? "")).lowercased()
        // Nintendo Switch 1 and 2: Joy-Con (alone or as a pair) and Pro Controller.
        let switch2 = name.contains("switch 2") || name.contains("joy-con 2") || name.contains("joy-con2")
            || name.contains("ns2")
        if name.contains("joy-con") || name.contains("joycon") { return switch2 ? .joyCon2 : .joyCon }
        if name.contains("pro controller") || name.contains("switch") { return switch2 ? .switch2Pro : .switchPro }
        guard let pad = controller.extendedGamepad else { return controller.microGamepad != nil ? .other : .none }
        if pad is GCDualSenseGamepad { return .dualSense }
        if pad is GCDualShockGamepad { return .dualShock4 }
        if pad is GCXboxGamepad { return .xboxSeries }
        let text = ((controller.productCategory) + " " + (controller.vendorName ?? "")).lowercased()
        if text.contains("dualsense") { return .dualSense }
        if text.contains("dualshock") || text.contains("wireless controller") { return .dualShock4 }
        if text.contains("360") { return .xbox360 }
        if text.contains("xbox") { return .xboxSeries }
        return .other
    }

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
        // Extended gamepads, and a single Joy-Con, which has only the micro profile:
        // the native bridge gives both a virtual Windows controller slot.
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil || $0.microGamepad != nil }
        let first = connected.first
        isControllerConnected = first != nil
        connectedKind = first.map(Self.kind(of:)) ?? .none
        if let first {
            let name = first.vendorName ?? connectedKind.label
            controllerName = name.localizedCaseInsensitiveContains(connectedKind.label) || connectedKind == .other
                ? name : "\(name) (\(connectedKind.label))"
        } else {
            controllerName = "None"
        }
    }

    @objc private func controllerConnectionChanged(_ notification: Notification) {
        refreshControllers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// The Windows controller APIs a game can be given, by console family. The stored
/// values are the old ones, so saved choices keep working.
enum ControllerAPI {
    static let choices = ["XInput", "XInput + DirectInput", "HID", "DualSense HID", "Nintendo Switch", "Generic HID"]

    static func label(_ value: String) -> String {
        switch value {
        case "By controller", "Automatic": return tr("Automatic (by controller)")
        case "XInput": return tr("Xbox (XInput): 360, One, Series")
        case "XInput + DirectInput": return tr("Xbox (XInput) + DirectInput")
        case "HID": return tr("PlayStation (HID): DualSense, DualShock 4")
        case "DualSense HID": return tr("PlayStation 5: DualSense (HID)")
        case "Nintendo Switch": return tr("Nintendo Switch 1 and 2: Joy-Con, Pro Controller")
        case "Generic HID": return tr("Generic HID controller")
        default: return tr(value)
        }
    }
}
