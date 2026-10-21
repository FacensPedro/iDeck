import SwiftUI

@main
struct iDeckApp: App {
    @StateObject private var systemCoordinator = SystemCoordinator()
    
    var body: some Scene {
        WindowGroup {
            MainView(coordinator: systemCoordinator)
        }
    }
}
