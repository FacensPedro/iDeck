import GameController
import SwiftUI

/// Xbox-style on-screen controller backed by GCVirtualController. The
/// virtual pad shows up to the game like any other extended gamepad, so
/// the existing InputManager / Wine bridge picks it up unchanged.
@MainActor
final class TouchController: ObservableObject {
    static let shared = TouchController()

    enum Element: String, CaseIterable, Identifiable {
        case leftStick, rightStick, dpad, faceButtons, shoulders, triggers, menu
        var id: String { rawValue }
        var title: String {
            switch self {
            case .leftStick: return "Left stick"
            case .rightStick: return "Right stick"
            case .dpad: return "D-pad"
            case .faceButtons: return "A / B / X / Y"
            case .shoulders: return "LB / RB"
            case .triggers: return "LT / RT"
            case .menu: return "Menu / View"
            }
        }
        var gcElements: [String] {
            switch self {
            case .leftStick: return [GCInputLeftThumbstick]
            case .rightStick: return [GCInputRightThumbstick]
            case .dpad: return [GCInputDirectionPad]
            case .faceButtons: return [GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY]
            case .shoulders: return [GCInputLeftShoulder, GCInputRightShoulder]
            case .triggers: return [GCInputLeftTrigger, GCInputRightTrigger]
            case .menu: return [GCInputButtonMenu, GCInputButtonOptions]
            }
        }
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "touchControllerEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "touchControllerEnabled"); objectWillChange.send(); refresh() }
    }
    @Published private(set) var hidden: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "touchControllerHidden") ?? [Element.dpad.rawValue])
    }()

    private var controller: GCVirtualController?
    private var active = false

    func isShown(_ e: Element) -> Bool { !hidden.contains(e.rawValue) }

    func setShown(_ e: Element, _ shown: Bool) {
        if shown { hidden.remove(e.rawValue) } else { hidden.insert(e.rawValue) }
        UserDefaults.standard.set(Array(hidden), forKey: "touchControllerHidden")
        // GCVirtualController's element set is fixed at creation.
        rebuild()
    }

    func sessionStarted() { active = true; refresh() }
    func sessionEnded() { active = false; refresh() }

    private func refresh() {
        let want = active && enabled && physicalControllerMissing
        if want, controller == nil { rebuild() }
        if !want { controller?.disconnect(); controller = nil }
    }

    private var physicalControllerMissing: Bool {
        !GCController.controllers().contains { !$0.isSnapshot && $0.extendedGamepad != nil && !isVirtual($0) }
    }

    private func isVirtual(_ c: GCController) -> Bool {
        controller?.controller === c
    }

    private func rebuild() {
        controller?.disconnect()
        controller = nil
        guard active && enabled else { return }
        let cfg = GCVirtualController.Configuration()
        cfg.elements = Set(Element.allCases.filter(isShown).flatMap(\.gcElements))
        let vc = GCVirtualController(configuration: cfg)
        vc.connect()
        controller = vc
    }
}

/// Sheet opened from the session toolbar: FPS overlay and touch layout.
struct SessionControlsSheet: View {
    @ObservedObject var touch = TouchController.shared
    @AppStorage("showGamePerformanceOverlay") private var showFPS = false
    @AppStorage("touchControllerEnabled") private var touchEnabled = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("Show FPS"), isOn: $showFPS)
                }
                Section(tr("Touch controller")) {
                    Toggle(tr("Touch controller"), isOn: Binding(
                        get: { touchEnabled },
                        set: { touchEnabled = $0; touch.enabled = $0 }))
                    if touchEnabled {
                        ForEach(TouchController.Element.allCases) { e in
                            Toggle(tr(e.title), isOn: Binding(
                                get: { touch.isShown(e) },
                                set: { touch.setShown(e, $0) }))
                        }
                    }
                }
            }
            .navigationTitle(tr("Controls"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
