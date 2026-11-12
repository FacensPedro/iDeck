import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / "iDeck" / name).read_text()


class Release20Tests(unittest.TestCase):
    def test_achievements_card(self):
        self.assertIn("\"achievements\"", read("GameDetailComponents.swift"))
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

    def test_i386_farm_key_ignores_the_components_script(self):
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        line = next(l for l in workflow.splitlines() if "madeira-i386-farm-" in l)
        self.assertNotIn("build_madeira_components.sh", line)
        self.assertIn("native_fp.outputs.i386", line)

    def test_no_multiversus(self):
        self.assertNotIn("multiversus", read("WindowsLibraryModels.swift").lower())
        self.assertNotIn("multiversus", (ROOT / "RELEASE_NOTES.md").read_text().lower())


if __name__ == "__main__":
    unittest.main()
