import SwiftUI

@main
struct iDeckApp: App {
    @StateObject private var coordinator = SystemCoordinator()

    init() {
        ideck_native_memory_install_notifications()
        _ = ideck_native_memory_configure(64 * 1024 * 1024, 8 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            MainView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
