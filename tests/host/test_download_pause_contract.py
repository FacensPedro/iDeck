import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STEAM = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
GOG = (ROOT / "iDeck/GOGLibrary.swift").read_text(encoding="utf-8")
EPIC = (ROOT / "iDeck/EpicLibrary.swift").read_text(encoding="utf-8")
RELAY = (ROOT / "iDeck/IRelayDeviceService.swift").read_text(encoding="utf-8")
VIEW = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
TRANSLATIONS = (ROOT / "iDeck/Localization.swift").read_text(encoding="utf-8")


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

    def test_pc_status_poll_recovers_temporary_usb_errors(self):
        downloader = (ROOT / "iDeck/SwiftSteam/Content/DepotDownloader.swift").read_text(encoding="utf-8")
        self.assertIn("var reconnectDeadline: Date?", downloader)
        self.assertIn("addingTimeInterval(65)", downloader)
        self.assertIn("USB status recovered", downloader)
        self.assertIn("USB poll unavailable", downloader)
        self.assertIn("await pc.cancelProcess(job)", downloader)

    def test_usb_http_receiver_uses_small_network_slabs(self):
        self.assertIn("maximumLength: 256 << 10", RELAY)
        self.assertIn('case ("PUT", "/write"):', RELAY)
        self.assertIn('SHA-1 mismatch', RELAY)

    def test_device_service_exposes_store_agnostic_transfer_controls(self):
        self.assertIn('case ("POST", "/downloads/control"):', RELAY)
        self.assertIn('"protocol": 3', RELAY)
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
