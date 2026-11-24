import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = (ROOT / "iDeck/SteamLibraryPreviewCache.swift").read_text()
MANAGER = (ROOT / "iDeck/SteamManager.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
COMPAT = (ROOT / "iDeck/SessionCompatibility.swift").read_text()


class SteamLaunchOptionsCacheTests(unittest.TestCase):
    def test_launch_options_survive_the_fresh_process(self):
        self.assertIn("var launches: [SteamCachedLaunch]? = nil", CACHE)
        self.assertIn("struct SteamCachedLaunch: Codable, Sendable, Equatable", CACHE)
        self.assertIn("launches: game.launches.isEmpty ? nil : game.launches.map {", MANAGER)
        self.assertIn("app.launches = (cached.launches ?? []).map {", MANAGER)


class SteamClientNeedTests(unittest.TestCase):
    def test_markers(self):
        self.assertIn('"steam://run/\\(appID)"', COMPAT)
        self.assertIn('"[s_api fail]"', COMPAT)
        self.assertIn("static let quickExitSeconds: TimeInterval = 60", COMPAT)

    def test_direct_launch_is_timed_and_checked_at_session_end(self):
        self.assertIn("directSteamStartedAt = Date()", COORD)
        self.assertIn("SteamClientNeed.markers(appID: appID)", COORD)
        self.assertIn("SteamClientNeed.note(appID)", COORD)
        self.assertIn("The game needs Steam's Windows client. It asked for Steam and closed", COORD)

    def test_games_that_need_the_client_skip_the_direct_path(self):
        self.assertIn("let needsClient = SteamClientNeed.needs(game.appID)", COORD)
        self.assertIn("let skipSteamClient = !needsClient && (skipSteamClient || Self.directSteamLaunchAppIDs.contains(game.appID))", COORD)


if __name__ == "__main__":
    unittest.main()
