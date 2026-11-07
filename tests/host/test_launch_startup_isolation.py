import unittest
from pathlib import Path

from support import ROOT, repo_text
APP = repo_text("iDeck/iDeckApp.swift")
MAIN = repo_text("iDeck/MainView.swift")
COORDINATOR = repo_text("iDeck/SystemCoordinator.swift")


class LaunchStartupIsolationTests(unittest.TestCase):
    def test_app_entry_does_not_initialize_native_jit_or_memory(self):
        self.assertIn('NSLog("[iDeck startup] SwiftUI App initialized', APP)
        self.assertNotIn("ideck_native_memory_install_notifications()", APP)
        self.assertNotIn("ideck_native_memory_configure(", APP)
        self.assertNotIn("ideck_fex_initialize(", APP)

    def test_coordinator_startup_never_calls_native_or_keychain(self):
        body = COORDINATOR.split("    init() {", 1)[1].split("    /// The installer's latest message", 1)[0]
        self.assertNotIn("refreshJITStatus()", body)
        self.assertNotIn("SteamSignIn.isSignedIn", body.replace(
            "self.isSteamConnected = SteamSignIn.isSignedIn", ""))
        self.assertNotIn("ideck_wine_jit_pool_ready()", body)
        self.assertIn("private var steamSignInLoaded = false", COORDINATOR)
        self.assertIn("func loadSteamAccountIfNeeded()", COORDINATOR)

    def test_one_memory_pressure_handler_and_deferred_first_paint(self):
        # ResourceGovernor (Swift) is the only memory-pressure handler; the
        # native pool that held no allocations is gone.
        self.assertNotIn("ideck_native_memory", COORDINATOR)
        self.assertIn("DispatchSource.makeMemoryPressureSource", repo_text("iDeck/ResourceGovernor.swift"))
        self.assertIn("await Task.yield()", MAIN)

    def test_madeira_replaces_home_and_preserves_deferred_jit_checks(self):
        main = MAIN.split("struct MainView: View {", 1)[1].split("struct SteamGameArtworkView:", 1)[0]
        self.assertIn("@State private var steamLibrary: SteamOwnedGamesModel?", main)
        self.assertIn("steamLibrary = SteamOwnedGamesModel.shared", main)
        self.assertIn("WindowsWorkspaceView(coordinator: coordinator, steamLibrary: steamLibrary)", main)
        self.assertNotIn("homeView", main)
        self.assertNotIn("selectedWorkspace", main)
        self.assertNotIn("private struct WorkspaceHostView: View", MAIN)
        self.assertIn("steamLibrary != nil && scenePhase == .active", main)
        self.assertIn("steamLibrary != nil && coordinator.isSteamConnected", main)
        self.assertIn("await steamLibrary.refresh()", main)
        self.assertIn('NSLog("[iDeck startup] Madeira library is the root view")', main)

    def test_madeira_loads_library_without_requesting_jit(self):
        root = MAIN.split("struct MainView: View {", 1)[1].split("struct SteamGameArtworkView:", 1)[0]
        self.assertIn("coordinator.loadSteamAccountIfNeeded()", root)
        self.assertIn("coordinator.openMadeiraWorkspace()", root)
        self.assertNotIn("coordinator.forceJITAndStartWindows()", root)
        self.assertNotIn("coordinator.reconnectStikDebugForWineIfNeeded()", root)
        self.assertIn("guard ensureJITForGameLaunch() else { return }", COORDINATOR)


if __name__ == "__main__":
    unittest.main()
