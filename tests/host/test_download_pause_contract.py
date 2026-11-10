import unittest
from pathlib import Path

from support import ROOT, repo_text
STEAM = repo_text("iDeck/SteamManager.swift")
GOG = repo_text("iDeck/GOGLibrary.swift")
EPIC = repo_text("iDeck/EpicLibrary.swift")
VIEW = repo_text("iDeck/MainView.swift")
TRANSLATIONS = repo_text("iDeck/Localization.swift")


class DownloadPauseContractTests(unittest.TestCase):
    def test_steam_user_pause_keeps_partials_and_can_resume(self):
        self.assertIn("func pauseInstall(appID: UInt32)", STEAM)
        self.assertIn("func resumeInstall(appID: UInt32)", STEAM)
        self.assertIn("if cancelled, pausedInstalls.contains(appID)", STEAM)
        self.assertIn("userPausedPrefixes[appID] = prefix", STEAM)
        self.assertIn("stoppingPausedInstalls.insert(appID)", STEAM)

    def test_gog_pause_separate_from_stop_and_epic_already_supports_both(self):
        self.assertIn("func pauseDownload(_ game: GOGGame)", GOG)
        self.assertIn("func resumeDownload(_ game: GOGGame)", GOG)
        self.assertIn("func cancelDownload(_ game: GOGGame)", GOG)
        self.assertIn("func pause(_ app: String)", EPIC)
        self.assertIn("func cancel(_ app: String)", EPIC)

    def test_irelay_stop_waits_for_owned_steam_files_cleanup(self):
        self.assertIn("func cancelInstallAndWait(appID: UInt32) async", STEAM)
        self.assertIn("await previous?.value", STEAM)
        self.assertIn("await cleanup?.value", STEAM)
        self.assertIn("func cancelDownloadAndWait(_ game: GOGGame) async", GOG)
        self.assertIn("func cancelAndWait(_ app: String) async", EPIC)

    def test_interface_distinguishes_pause_stop_and_resume(self):
        self.assertIn('tr("Pause download")', VIEW)
        # The controls are on each game's page, not under its library card.
        self.assertIn("steamLibrary.pauseInstall(appID: game.appID)", VIEW)
        self.assertIn("gog.resumeDownload(game)", VIEW)
        self.assertIn("epic.pause(appName)", VIEW)
        self.assertIn("epic.cancel(appName)", VIEW)
        self.assertNotIn("cardActionLabel(", VIEW)
        self.assertIn('"Download paused": ["pt": "Download pausado"', TRANSLATIONS)


if __name__ == "__main__":
    unittest.main()
