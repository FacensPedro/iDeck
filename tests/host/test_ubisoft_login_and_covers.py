import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text()
MAIN = (ROOT / "iDeck/MainView.swift").read_text()


class UbisoftLoginAndCoverTests(unittest.TestCase):
    def test_login_saved_in_keychain_after_success(self):
        self.assertIn("enum UbisoftSavedLogin {", SETTINGS)
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", SETTINGS)
        self.assertIn("if let pendingLogin { UbisoftSavedLogin.save(email: pendingLogin.0, password: pendingLogin.1) }", SETTINGS)
        self.assertIn("if email.isEmpty, let saved = UbisoftSavedLogin.load() {", SETTINGS)

    def test_sign_out_deletes_the_saved_login(self):
        self.assertIn("UbisoftSavedLogin.remove()\n                        if UbisoftSavedSession.clear()", SETTINGS)

    def test_no_text_over_ubisoft_covers(self):
        self.assertNotIn("fallbackTitle: game.title", MAIN)

    def test_notifications_off_unless_allowed(self):
        self.assertIn("if status != .authorized && status != .provisional && status != .ephemeral { downloadNotifications = false }", SETTINGS)


if __name__ == "__main__":
    unittest.main()
