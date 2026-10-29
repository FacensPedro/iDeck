import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = (ROOT / "iDeck/GameSessionView.swift").read_text()
BRIDGE = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text()
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text()
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
ENTITLEMENTS = (ROOT / "iDeck/iDeck.entitlements").read_text()
PROFILES = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
UI = (ROOT / "iDeck/MainView.swift").read_text()


class WineStartupSessionTests(unittest.TestCase):
    def test_progress_is_milestone_not_fake_game_download(self):
        self.assertIn("private var gameLoading:", VIEW)
        self.assertIn("ProgressView(value: loading.progress, total: 1)", VIEW)
        self.assertIn('0.90, "Waiting for the first game frame"', VIEW)
        self.assertIn('1.0, "First Metal frame displayed"', VIEW)
        self.assertIn("metrics.receivedNewFrames", VIEW)
        self.assertIn("Startup milestone, not the game's internal loading percentage.", VIEW)

    def test_close_uses_native_madeira_keyboard_queue(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn("Button(action: coordinator.requestCloseWindowsSession)", VIEW)
        self.assertIn("ideck_wineprocess_request_close()", coordinator)
        self.assertIn("ideck_wineprocess_request_close(void)", HEADER)
        self.assertIn('"winios_post_key"', BRIDGE)
        self.assertIn("post(0x12, 1)", BRIDGE)
        self.assertIn("post(0x73, 1)", BRIDGE)
        self.assertIn("post(0x73, 0)", BRIDGE)
        self.assertIn("post(0x12, 0)", BRIDGE)
        self.assertIn("coordinator.pollWindowsSessionClose()", VIEW)
        self.assertIn("Closing Wine and wineserver...", VIEW)
        self.assertIn("ideck_runtime_complete_session()", coordinator)
        self.assertIn("!ideck_wineprocess_running() && !ideck_wineserver_running()", coordinator)

    def test_wine_session_is_locked_until_previous_session_fully_exits(self):
        self.assertIn("ideck_wine_session_started", NATIVE)
        self.assertIn("if (ideck_wine_session_started) return EALREADY;", NATIVE)
        self.assertIn("ideck_wine_session_started = false", NATIVE)
        self.assertIn("ideck_wineprocess_running() || ideck_wineserver_running()", NATIVE)

    def test_steam_working_folder_is_set_for_relative_assets(self):
        self.assertIn('setenv("MADEIRA_STEAM_APPPATH", windowsFolder.UTF8String, 1)', NATIVE)
        self.assertIn('setenv("MADEIRA_WORKDIR", windowsWorkingDirectory.UTF8String, 1)', NATIVE)
        self.assertIn('request[@"steamWorkingDirectory"]', NATIVE)
        self.assertIn('unsetenv("MADEIRA_WORKDIR")', NATIVE)
        self.assertIn("MADEIRA_WORKDIR", NATIVE)
        self.assertNotIn('setenv("MADEIRA_WORKDIR", windowsFolder.UTF8String, 1)', NATIVE)

    def test_opt_in_child_process_compatibility(self):
        self.assertIn("var keepChildProcessesRunning: Bool = false", PROFILES)
        self.assertIn("decodeIfPresent(Bool.self, forKey: .keepChildProcessesRunning) ?? false", PROFILES)
        self.assertIn('setenv("MADEIRA_WAIT_CHILDREN", "1", 1)', ENVIRONMENT)
        self.assertIn('unsetenv("MADEIRA_WAIT_CHILDREN")', ENVIRONMENT)
        self.assertIn("isOn: $profile.keepChildProcessesRunning", UI)

    def test_memory_entitlement_is_requested(self):
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", ENTITLEMENTS)


if __name__ == "__main__":
    unittest.main()
