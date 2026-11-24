import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / "iDeck/MainView.swift").read_text()
UBI = (ROOT / "iDeck/UbisoftDownloader.swift").read_text()


class DetailButtonSizeTests(unittest.TestCase):
    def test_launch_and_uninstall_match_install(self):
        self.assertEqual(MAIN.count(".frame(maxWidth: 220)"), 6)
        self.assertNotIn('Label(tr("Launch"), systemImage: "play.fill")\n                    .frame(maxWidth: .infinity)', MAIN)


class UbisoftClientVersionTests(unittest.TestCase):
    def test_installed_version_is_sent_when_newer(self):
        self.assertIn("static let builtInClientVersion: UInt64 = 10931", UBI)
        self.assertIn("UbisoftConnectInstaller.exe", UBI)
        self.assertIn("if build > builtInClientVersion && build < 100_000 {", UBI)
        self.assertIn("for field in [version.patch, version.build] {", UBI)
        self.assertIn('"[ubisoft-demux] client version', UBI)


if __name__ == "__main__":
    unittest.main()
