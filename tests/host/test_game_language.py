import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPAT = (ROOT / "iDeck/SessionCompatibility.swift").read_text()
VIEW = (ROOT / "iDeck/GameDetailComponents.swift").read_text()
MAIN = (ROOT / "iDeck/MainView.swift").read_text()


class GameLanguageTests(unittest.TestCase):
    def test_automatic_falls_back_to_ideck_language(self):
        self.assertIn("return AppLanguage.gameLocale(separator: separator)", COMPAT)

    def test_each_store_uses_the_choice(self):
        self.assertIn('GameLanguage.locale("epic:" + app, separator: "-")', (ROOT / "iDeck/EpicLibrary.swift").read_text())
        self.assertIn('GameLanguage.locale("ea:" + id, separator: "_")', (ROOT / "iDeck/EALibrary.swift").read_text())
        self.assertIn('GameLanguage.choice("gog:\\(gameID)")', (ROOT / "iDeck/GOGContentSystem.swift").read_text())
        self.assertIn('GameLanguage.choice("ubisoft:\\(game.id)")', (ROOT / "iDeck/UbisoftLibrary.swift").read_text())
        self.assertIn("SteamLanguage.chooseForGame(app, tag.flatMap(steamName))", COMPAT)

    def test_steam_audio_and_subtitles(self):
        info = (ROOT / "iDeck/SwiftSteam/Library/SteamAppInfo.swift").read_text()
        self.assertIn('fields?["full_audio"]', info)
        self.assertIn('fields?["subtitles"]', info)
        self.assertIn('case (true, true): return name + " — " + tr("Audio + subtitles")', VIEW)

    def test_card_on_every_store_page(self):
        self.assertIn('GameLanguageCard(profileID: "steam:\\(game.appID)",', MAIN)
        self.assertIn("GameLanguageCard(profileID: profileID, available: GameLanguage.known(profileID))", MAIN)


if __name__ == "__main__":
    unittest.main()
