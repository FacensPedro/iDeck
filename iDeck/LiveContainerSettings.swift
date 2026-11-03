import SwiftUI

/// Settings › LiveContainer.
struct LiveContainerSettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator

    var body: some View {
        Form {
            Section {
                Toggle(tr("Inject Guest Hooks"), isOn: $coordinator.isGuestHooksEnabled)
            }
        }
        .navigationTitle("LiveContainer")
    }
}
