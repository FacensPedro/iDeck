import SwiftUI

/// Sheet opened from the session's gear button: FPS, touch, MetalFX and the
/// running game's frame-rate limit.
struct SessionControlsSheet: View {
    @ObservedObject var coordinator: SystemCoordinator
    @StateObject private var library = WindowsLibraryStore()
    @AppStorage("showGamePerformanceOverlay") private var showFPS = false
    @AppStorage("touchMouseEnabled") private var touch = true
    @AppStorage(SteamCloudAutoSave.key) private var autoSave = false
    @Environment(\.dismiss) private var dismiss

    private var profile: WindowsGameProfile? {
        coordinator.activeWindowsProfile.map { library.profile(for: $0.id, title: $0.title) }
    }

    private func binding<Value>(_ path: WritableKeyPath<WindowsGameProfile, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(
            get: { profile?[keyPath: path] ?? fallback },
            set: { value in
                guard var current = profile else { return }
                current[keyPath: path] = value
                library.save(current)
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(tr("Show FPS"), isOn: $showFPS)
                    Toggle(tr("Touch screen"), isOn: $touch)
                    Toggle(tr("Auto Save"), isOn: $autoSave)
                }
                Section {
                    Toggle(tr("MetalFX Upscaling"), isOn: binding(\.metalFXEnabled, false))
                    Picker(tr("Frame rate limit"), selection: binding(\.fpsLimit, "60")) {
                        ForEach(WindowsGameProfile.fpsLimits, id: \.self) { Text(tr($0)).tag($0) }
                    }
                } footer: {
                    Text(tr("MetalFX and the FPS limit take effect the next time a game starts. A lower limit uses less CPU, GPU and battery."))
                }
                .disabled(profile == nil)
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

/// Steam Cloud "Auto Save": sync a game's saves when its page opens. Off by default.
enum SteamCloudAutoSave {
    static let key = "iDeck.steamCloud.autoSaveEnabled"
}
