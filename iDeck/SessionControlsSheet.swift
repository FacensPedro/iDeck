import SwiftUI

/// Sheet opened from the session toolbar: FPS overlay and touch-as-mouse.
struct SessionControlsSheet: View {
    @AppStorage("showGamePerformanceOverlay") private var showFPS = false
    @AppStorage("touchMouseEnabled") private var touchMouse = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("Show FPS"), isOn: $showFPS)
                    Toggle(tr("Touch screen as mouse"), isOn: $touchMouse)
                }
            }
            .navigationTitle(tr("Settings"))
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
