import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / "iDeck" / name).read_text()


class Release20Tests(unittest.TestCase):
    def test_achievements_card(self):
        self.assertIn("filters=achievements", read("GameDetailComponents.swift"))
        self.assertIn("SteamAchievementsCard(appID: game.appID)", read("MainView.swift"))

    def test_easy_anti_cheat_blocked_in_every_store(self):
        models = read("WindowsLibraryModels.swift")
        for appID in ("252950", "1097150", "1222730"):
            self.assertIn(appID, models)
        self.assertIn('"fortnite"', models)
        for store in ("SteamManager.swift", "GOGLibrary.swift", "EpicLibrary.swift", "EALibrary.swift"):
            self.assertIn("AntiCheatPolicy.isBlocked", read(store), store)

    def test_game_language_follows_ideck(self):
        self.assertIn("AppLanguage.chosenCode", read("SwiftSteam/Library/SteamAppInfo.swift"))
        self.assertIn('AppLanguage.gameLocale(separator: "_")', read("EALibrary.swift"))
        self.assertIn('AppLanguage.gameLocale(separator: "-")', read("EpicLibrary.swift"))

    def test_stores_in_separate_sections(self):
        page = read("SettingsView.swift").split("private var accountsPage")[1].split("private var eaPage")[0]
        self.assertEqual(page.count("Section"), 4)


if __name__ == "__main__":
    unittest.main()
