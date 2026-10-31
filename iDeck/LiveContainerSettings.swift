import SwiftUI

/// Settings › LiveContainer.
struct LiveContainerSettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator

    var body: some View {
        Form {
            Section {
                Toggle(tr("Inject Guest Hooks"), isOn: $coordinator.isGuestHooksEnabled)
            } footer: {
                Text(tr("Guest hooks make a hosted app see its own bundle, data folder and preferences."))
            }
        }
        .navigationTitle("LiveContainer")
    }
}
