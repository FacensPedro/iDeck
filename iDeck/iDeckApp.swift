import SwiftUI

@main
struct iDeckApp: App {
    @StateObject private var coordinator = SystemCoordinator()

    var body: some Scene {
        WindowGroup {
            MainView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
