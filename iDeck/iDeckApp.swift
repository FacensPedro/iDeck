import SwiftUI

@main
struct iDeckApp: App {
    @StateObject private var coordinator = SystemCoordinator()

    init() {
        // As MadeiraApp.init: host pads as Windows.Gaming.Input gamepads, and no
        // Metal HUD insights; madeira.cfg values exported later win.
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        setenv("MADEIRA_WGI_HOST_PADS", "1", 0)
        // iRelay over the USB cable: listen from launch so the PC finds iDeck at once.
        // The prefix is Documents/wine (Madeira's); earlier builds' moves first.
        MadeiraDock.linkPrefix()
        IRelayRuntime.start()
        JITPoolList.ensureFile()
        NSLog("[iDeck startup] SwiftUI App initialized without native runtime setup")
    }

    var body: some Scene {
        WindowGroup {
            MainView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
