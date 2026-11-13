import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text()


class Fixes222Tests(unittest.TestCase):
    def test_built_in_never_falls_back_silently(self):
        coord = read("iDeck/SystemCoordinator.swift")
        self.assertIn("IDeckBuiltInJIT.unavailableReason", coord)
        self.assertIn("private func builtInFailed(_ message: String)", coord)

    def test_no_localdevvpn_hint(self):
        self.assertNotIn("LocalDevVPN, and a debug-signable iDeck", read("iDeck/SettingsView.swift"))

    def test_vcredist_not_in_windows_downloads(self):
        vc = read("iDeck/VisualCRuntimeBootstrap.swift")
        self.assertIn('FileManager.default.temporaryDirectory.appendingPathComponent("vcredist"', vc)

    def test_force_close(self):
        self.assertIn("func forceCloseIDeck()", read("iDeck/SystemCoordinator.swift"))
        self.assertIn('Button(tr("Close iDeck"), role: .destructive)', read("iDeck/GameSessionView.swift"))

    def test_ea_covers_fill(self):
        self.assertIn("fallbackColor: panelColor, fill: true)", read("iDeck/MainView.swift"))

    def test_epic_base_size(self):
        self.assertIn("var installTags: [String] = []", read("iDeck/EpicFormats.swift"))
        self.assertIn("$0.installTags.isEmpty", read("iDeck/EpicLibrary.swift"))


if __name__ == "__main__":
    unittest.main()
