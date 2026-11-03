import SwiftUI

/// Sheet opened from the session toolbar: FPS overlay.
struct SessionControlsSheet: View {
    @AppStorage("showGamePerformanceOverlay") private var showFPS = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("Show FPS"), isOn: $showFPS)
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
