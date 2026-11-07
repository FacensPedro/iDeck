import unittest

from support import repo_text


class BullyCrashFixesTests(unittest.TestCase):
    def test_bully_starts_directly_not_as_steam_child(self):
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertIn("static let directSteamLaunchAppIDs: Set<UInt32> = [12200]", coordinator)
        self.assertIn("let skipSteamClient = skipSteamClient || Self.directSteamLaunchAppIDs.contains(game.appID)", coordinator)

    def test_dxgi_mode_table_matches_user32_for_every_game(self):
        env = repo_text("iDeck/WindowsEnvironment.swift")
        launch = env.split("private func applyMadeiraLaunchEnvironment", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn('setenv("DXMT_WSI_MODE_TABLE", "1", 1)', launch)
        self.assertNotIn('unsetenv("DXMT_WSI_MODE_TABLE")', launch)


if __name__ == "__main__":
    unittest.main()
