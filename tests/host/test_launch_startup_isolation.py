import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = (ROOT / "iDeck/iDeckApp.swift").read_text(encoding="utf-8")
MAIN = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")


class LaunchStartupIsolationTests(unittest.TestCase):
    def test_app_entry_does_not_initialize_native_jit_or_memory(self):
        self.assertIn('NSLog("[iDeck startup] SwiftUI App initialized', APP)
        self.assertNotIn("ideck_native_memory_install_notifications()", APP)
        self.assertNotIn("ideck_native_memory_configure(", APP)
        self.assertNotIn("ideck_fex_initialize(", APP)

    def test_coordinator_startup_never_calls_native_or_keychain(self):
        body = COORDINATOR.split("    init() {", 1)[1].split("    func configureNativeHostIfNeeded()", 1)[0]
        self.assertNotIn("refreshJITStatus()", body)
        self.assertNotIn("SteamSignIn.isSignedIn", body.replace(
            "self.isSteamConnected = SteamSignIn.isSignedIn", ""))
        self.assertNotIn("ideck_wine_jit_pool_ready()", body)
        self.assertIn("private var steamSignInLoaded = false", COORDINATOR)
        self.assertIn("func loadSteamAccountIfNeeded()", COORDINATOR)

    def test_native_memory_setup_is_delayed_until_mode_selected(self):
        self.assertIn("func configureNativeHostIfNeeded()", COORDINATOR)
        self.assertIn("ideck_native_memory_install_notifications()", COORDINATOR)
        self.assertIn("ideck_native_memory_configure(64 * 1024 * 1024", COORDINATOR)
        self.assertEqual(MAIN.count("coordinator.configureNativeHostIfNeeded()"), 2)

    def test_home_does_not_create_steam_or_check_native_jit(self):
        main = MAIN.split("struct MainView: View {", 1)[1].split("private var homeView:", 1)[0]
        self.assertNotIn("@StateObject private var steamLibrary", main)
        self.assertNotIn("coordinator.refreshJITStatus()\n            UIApplication", main)
        self.assertIn("selectedWorkspace != nil && scenePhase == .active", main)
        self.assertIn('NSLog("[iDeck startup] Home view ready', main)
        self.assertIn("@State private var steamLibrary: SteamOwnedGamesModel?", main)
        self.assertNotIn("private struct WorkspaceHostView: View", MAIN)
        self.assertEqual(MAIN.count("if steamLibrary == nil { steamLibrary = SteamOwnedGamesModel() }"), 2)
        self.assertIn("await steamLibrary.refresh()", main)
        self.assertIn("selectedWorkspace == .pc && coordinator.isSteamConnected", main)

    def test_madeira_still_loads_steam_and_jit_when_requested(self):
        home = MAIN.split("private var homeView:", 1)[1].split("private func modeTile", 1)[0]
        self.assertIn("coordinator.loadSteamAccountIfNeeded()", home)
        self.assertIn("coordinator.forceJITAndStartWindows()", home)
        self.assertIn("coordinator.reconnectStikDebugForWineIfNeeded()", home)


if __name__ == "__main__":
    unittest.main()
