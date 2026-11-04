import SwiftUI

/// Sheet opened from the session's gear button: FPS, touch and MetalFX.
struct SessionControlsSheet: View {
    @ObservedObject var coordinator: SystemCoordinator
    @StateObject private var library = WindowsLibraryStore()
    @AppStorage("showGamePerformanceOverlay") private var showFPS = false
    @AppStorage("touchMouseEnabled") private var touch = true
    @Environment(\.dismiss) private var dismiss

    private var profile: WindowsGameProfile? {
        coordinator.activeWindowsProfile.map { library.profile(for: $0.id, title: $0.title) }
    }

    private var metalFX: Binding<Bool> {
        Binding(
            get: { coordinator.isMetalFXEnabled || (profile?.metalFXEnabled ?? false) },
            set: { on in
                if var current = profile {
                    current.metalFXEnabled = on
                    library.save(current)
                }
                if !on { coordinator.isMetalFXEnabled = false }
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("Show FPS"), isOn: $showFPS)
                    Toggle(tr("Touch screen"), isOn: $touch)
                }
                Section {
                    Toggle(tr("MetalFX Upscaling"), isOn: metalFX)
                        .disabled(profile == nil && !coordinator.isMetalFXEnabled)
                } footer: {
                    Text(tr("MetalFX takes effect the next time this game starts."))
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
