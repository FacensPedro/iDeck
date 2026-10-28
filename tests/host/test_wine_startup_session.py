import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = (ROOT / "iDeck/GameSessionView.swift").read_text()
BRIDGE = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text()
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text()
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
ENTITLEMENTS = (ROOT / "iDeck/iDeck.entitlements").read_text()


class WineStartupSessionTests(unittest.TestCase):
    def test_progress_is_milestone_not_fake_game_download(self):
        self.assertIn("private var gameLoading:", VIEW)
        self.assertIn("ProgressView(value: loading.progress, total: 1)", VIEW)
        self.assertIn('0.90, "Waiting for the first game frame"', VIEW)
        self.assertIn('1.0, "First Metal frame displayed"', VIEW)
        self.assertIn("metrics.receivedNewFrames", VIEW)
        self.assertIn("Startup milestone, not the game's internal loading percentage.", VIEW)

    def test_close_uses_native_madeira_keyboard_queue(self):
        self.assertIn("ideck_wineprocess_request_close()", VIEW)
        self.assertIn("ideck_wineprocess_request_close(void)", HEADER)
        self.assertIn('"winios_post_key"', BRIDGE)
        self.assertIn("post(0x12, 1)", BRIDGE)
        self.assertIn("post(0x73, 1)", BRIDGE)
        self.assertIn("post(0x73, 0)", BRIDGE)
        self.assertIn("post(0x12, 0)", BRIDGE)
        self.assertIn("if closeRequested && !ideck_wineprocess_running()", VIEW)
        self.assertIn("The Metal display stays attached until Wine stops.", VIEW)

    def test_single_wine_session_per_app_process(self):
        self.assertIn("ideck_wine_session_started", NATIVE)
        self.assertIn("if (ideck_wine_session_started) return EALREADY;", NATIVE)

    def test_steam_working_folder_is_set_for_relative_assets(self):
        self.assertIn('setenv("MADEIRA_WORKDIR", windowsFolder.UTF8String, 1)', NATIVE)
        self.assertIn('unsetenv("MADEIRA_WORKDIR")', NATIVE)
        self.assertIn("MADEIRA_WORKDIR", NATIVE)

    def test_memory_entitlement_is_requested(self):
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", ENTITLEMENTS)


if __name__ == "__main__":
    unittest.main()
