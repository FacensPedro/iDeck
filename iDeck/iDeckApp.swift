import SwiftUI
import SQLite3

@main
struct iDeckApp: App {
    @StateObject private var coordinator = SystemCoordinator()

    init() {
        // No shared URL cache: every response through URLSession.shared and the
        // default configurations was kept in RAM and in CFNetwork's Cache.db
        // (sqlite). Downloads write to disk themselves, and artwork has its own cache.
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
        // SQLite's page caches are process-wide: DXMT's shader cache and the system
        // frameworks share them. A 32 MB soft limit makes SQLite reuse pages
        // instead of growing with every database it opens.
        sqlite3_soft_heap_limit64(32 << 20)
        // As MadeiraApp.init: host pads as Windows.Gaming.Input gamepads, and no
        // Metal HUD insights; madeira.cfg values exported later win.
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        setenv("MADEIRA_WGI_HOST_PADS", "1", 0)
        // MP4/MOV video (Media Foundation's source on winegstreamer: FFmpeg,
        // VideoToolbox) for 64-bit games too; Madeira gives them only WMA by
        // default, so a game's intro videos failed (0xc00d36bb).
        // madeira.cfg env.MADEIRA_WG_64BIT = 0 turns it off again.
        setenv("MADEIRA_WG_64BIT", "1", 0)
        // A previous install without a matching normal exit might indicate
        // an OS termination, force quit, restart or power interruption.
        // Report the interruption, never assume Jetsam or discard game files.
        let diagnostics = UserDefaults.standard
        if let inFlight = diagnostics.string(forKey: "diagnostics.installInFlight"), !inFlight.isEmpty {
            AppLog.record("[startup] warning: previous Steam installation did not finish normally: \(inFlight); cause undetermined")
            diagnostics.removeObject(forKey: "diagnostics.installInFlight")
        }
        // The prefix is Documents/wine (Madeira's); earlier builds' moves first.
        MadeiraDock.linkPrefix()
        JITPoolList.ensureFile()
        // iOS crash reports (MetricKit) for wineserver and loader crashes in-process.
        IOSCrashDiagnostics.shared.start()
        NSLog("[iDeck startup] SwiftUI App initialized without native runtime setup")
    }

    var body: some Scene {
        WindowGroup {
            MainView(coordinator: coordinator)
                .preferredColorScheme(.dark)
                // Remembered for launches prepared off the main thread (MetalFX size).
                .onAppear { WindowsEnvironment.readScreenPixels() }
        }
    }
}
