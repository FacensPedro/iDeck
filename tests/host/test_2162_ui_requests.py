"""2.16.2 requests: language card, controllers, controller audio, texts, bug log, install queue."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
read = lambda p: (ROOT / p).read_text()


class Requests2162(unittest.TestCase):
    def test_language_card(self):
        card = read("iDeck/GameDetailComponents.swift")
        self.assertIn("private func savedSelection() -> String", card)
        self.assertIn('guard let available, !available.isEmpty else { return ["en-US"] }', card)
        self.assertNotIn("kept.isEmpty ? offered : kept", card)
        self.assertIn("steamLibrary.startInstall(appID: game.appID, prefixPath: prefixPath)", read("iDeck/MainView.swift"))

    def test_controllers(self):
        im = read("iDeck/InputManager.swift")
        for text in ("Xbox (XInput): 360, One, Series", "Nintendo Switch 1 and 2: Joy-Con, Pro Controller", "joyCon2", "switch2Pro"):
            self.assertIn(text, im)
        self.assertIn('if controllerMode == "Nintendo Switch" { controllerMode = "XInput" }', read("iDeck/WindowsEnvironment.swift"))

    def test_controller_audio_rechecked(self):
        self.assertIn("ControllerAudioGuard.shared.recheck()", read("iDeck/SystemCoordinator.swift"))
        self.assertIn("port.portType == .usbAudio", read("iDeck/AudioManager.swift"))

    def test_texts_removed(self):
        main = read("iDeck/MainView.swift")
        self.assertNotIn("Games iDeck recognises get the settings they were tested with.", main)
        self.assertNotIn("Automatically sync Steam Cloud saves before playing", main)
        self.assertIn("Session expired. Sign in again to continue.", read("iDeck/SettingsView.swift"))

    def test_bug_log(self):
        view = read("iDeck/BugReportView.swift")
        self.assertNotIn('Toggle(tr("Record benchmarks")', view)
        self.assertIn('lines.append("Benchmarks (newest first):")', view)
        self.assertIn("if !force, stamp == lastScanStamp { return }", view)
        self.assertNotIn("Pause or finish the download and transfer before clearing logs.", view)

    def test_builtin_jit_vpn_retry(self):
        coord = read("iDeck/SystemCoordinator.swift")
        self.assertIn('response.message.contains("Timed out connecting")', coord)
        self.assertIn("Self.builtInVPNRetries < 3", coord)

    def test_epic_safari_sign_in_connects_by_itself(self):
        api = read("iDeck/EpicAPI.swift")
        self.assertIn('"/account/api/oauth/deviceAuthorization"', api)
        self.assertIn('"grant_type": "device_code"', api)
        self.assertIn('"grant_type": "exchange_code"', api)
        self.assertIn("func signInWithSafari(open:", read("iDeck/EpicLibrary.swift"))
        self.assertIn("startSafariSignIn()", read("iDeck/EpicGames.swift"))

    def test_install_queue(self):
        self.assertIn("@Published private(set) var waitingApps: [UInt32] = []", read("iDeck/SteamManager.swift"))
        self.assertIn('steamLibrary.waitingApps.contains(game.appID) ? tr("Waiting")', read("iDeck/MainView.swift"))


if __name__ == "__main__":
    unittest.main()
