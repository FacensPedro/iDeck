import unittest
from pathlib import Path

from support import ROOT, repo_text
STEAM = repo_text("iDeck/SteamManager.swift")
GOG = repo_text("iDeck/GOGLibrary.swift")
EPIC = repo_text("iDeck/EpicLibrary.swift")
RELAY = repo_text("iDeck/IRelayDeviceService.swift")
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
        self.assertIn("await steam.cancelInstallAndWait(appID: id)", RELAY)
        self.assertIn("await gog.cancelDownloadAndWait(game)", RELAY)
        self.assertIn("await EpicLibrary.shared.cancelAndWait(app)", RELAY)
        self.assertIn("func cancelDownloadAndWait(_ game: GOGGame) async", GOG)
        self.assertIn("func cancelAndWait(_ app: String) async", EPIC)

    def test_pc_status_poll_recovers_temporary_network_errors(self):
        downloader = repo_text("iDeck/SwiftSteam/Content/DepotDownloader.swift")
        self.assertIn("var reconnectDeadline: Date?", downloader)
        self.assertIn("addingTimeInterval(65)", downloader)
        self.assertIn("[irelay] status recovered", downloader)
        self.assertIn("[irelay] poll unavailable", downloader)
        self.assertIn("await pc.cancelProcess(job)", downloader)

    def test_http_receiver_uses_small_network_slabs(self):
        self.assertIn("maximumLength: 256 << 10", RELAY)
        self.assertIn('case ("PUT", "/write"):', RELAY)
        self.assertIn('SHA-1 mismatch', RELAY)

    def test_device_service_exposes_store_agnostic_transfer_controls(self):
        self.assertIn('case ("POST", "/downloads/control"):', RELAY)
        self.assertIn('"protocol": 4', RELAY)
        self.assertIn('UbisoftLibrary.installRoot + "/"', RELAY)
        self.assertNotIn('"WindowsDownloads/Launchers/"', RELAY)
        for store in ('"steam"', '"gog"', '"epic"'):
            self.assertIn(f'case {store}:', RELAY)
        for action in ("pause", "resume", "stop"):
            self.assertIn(f'"{action}"', RELAY)

    def test_interface_distinguishes_pause_stop_and_resume(self):
        self.assertIn('tr("Pause download")', VIEW)
        self.assertIn("steamLibrary.resumeInstall(appID: game.appID)", VIEW)
        self.assertIn("gogLibrary.resumeDownload(game)", VIEW)
        self.assertIn("epicLibrary.pause(game.appName)", VIEW)
        self.assertIn("epicLibrary.cancel(game.appName)", VIEW)
        self.assertIn('"Download paused": ["pt": "Download pausado"', TRANSLATIONS)


if __name__ == "__main__":
    unittest.main()
