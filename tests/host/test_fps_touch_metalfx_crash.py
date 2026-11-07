import unittest

from support import repo_text

ENV = repo_text("iDeck/WindowsEnvironment.swift")
RENDERER = repo_text("iDeck/WindowsRendererView.swift")
CONFIG = repo_text("iDeck/RuntimeConfiguration.swift")
SHEET = repo_text("iDeck/SessionControlsSheet.swift")
RECS = repo_text("iDeck/GameRecommendations.swift")


class FPSTouchMetalFXCrashTests(unittest.TestCase):
    def test_fps_limit_sets_dxmt_present_mode(self):
        self.assertIn('NativeSymbol.address("madeira_set_vsync_locked")', ENV)
        self.assertIn('case "30": return 3', ENV)
        self.assertIn('case "40": return 4', ENV)
        self.assertIn('case "Uncapped": return 0', ENV)
        self.assertIn("Self.applyFrameRateLimit(profile.fpsLimit)", ENV)
        self.assertIn("WindowsEnvironment.applyFrameRateLimit(limit)", SHEET)

    def test_touch_maps_into_game_client_rect(self):
        self.assertIn('NativeSymbol.address("winios_game_client_rect")', RENDERER)
        self.assertIn("RuntimeConfiguration.clientPoint(point, client: client", RENDERER)
        self.assertIn("static func clientPoint(", CONFIG)

    def test_metalfx_uses_this_screen_off_the_main_thread(self):
        self.assertIn(": Self.screenPixels", ENV)
        self.assertNotIn(": CGSize(width: 2732, height: 2048)\n", ENV.split("let screen: CGSize", 1)[1][:400])
        self.assertIn("WindowsEnvironment.readScreenPixels()", repo_text("iDeck/iDeckApp.swift"))

    def test_crash_bandicoot_gets_dxgi_mode_table(self):
        block = RECS.split("static let crashBandicootNSane = GameRecommendation(", 1)[1].split("static let standard", 1)[0]
        self.assertIn("env.DXMT_WSI_MODE_TABLE = 1", block)
        self.assertIn("env.DXMT_WSI_MONITOR_IDENTITY = 1", block)
        self.assertIn("steamAppID == crashBandicootNSaneAppID", RECS)
        self.assertIn('case "crashbandicootnsanetrilogy.exe":', RECS)
        self.assertIn("crashBandicootNSane, standard]", RECS)


if __name__ == "__main__":
    unittest.main()
