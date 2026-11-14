import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text()


class SettingsAndRamTests(unittest.TestCase):
    def test_settings(self):
        s = read("iDeck/SettingsView.swift")
        self.assertNotIn("does not guarantee that FEX is ready", s)
        self.assertIn('if jitMethod == "builtIn" {', s)
        self.assertIn("UIScreen.main.maximumFramesPerSecond > 60", s)
        self.assertIn(".disabled(notificationsDenied)", s)
        self.assertIn("if notificationsDenied { downloadNotifications = false }", s)

    def test_advanced_notes_short(self):
        r = read("iDeck/MadeiraRuntimeSettings.swift")
        self.assertIn("private var d3d9Note: String?", r)
        self.assertNotIn("DXMT draws Direct3D 9 on Metal", r)

    def test_ram(self):
        self.assertIn("var memoryBudget = 64 << 20", read("iDeck/EpicDownloader.swift"))
        self.assertIn("static let segmentBytes: Int64 = 4 << 20", read("iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift"))
        self.assertIn('NotificationCenter.default.post(name: Notification.Name("iDeckReleaseCaches"), object: nil)',
                      read("iDeck/SystemCoordinator.swift"))


if __name__ == "__main__":
    unittest.main()
