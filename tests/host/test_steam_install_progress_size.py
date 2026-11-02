import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SteamInstallProgressAccountingTests(unittest.TestCase):
    def test_portuguese_and_spanish_install_labels(self):
        localization = (ROOT / "iDeck/Localization.swift").read_text(encoding="utf-8")
        self.assertIn('"Installed: %@": ["pt": "Instalado: %@", "es": "Instalado: %@"]', localization)
        self.assertIn('"Installing %d%%": ["pt": "Instalando %d%%", "es": "Instalando %d%%"]', localization)
        self.assertNotIn('"Already on device: %@"', localization)
        self.assertNotIn('"Downloading %d%%"', localization)

    def test_swift_host_suite_checks_real_install_size(self):
        fixture = (ROOT / "tests/host/SteamInstallLaunchPathTests.swift").read_text(encoding="utf-8")
        self.assertIn("SteamInstallFiles.logicalInstalledSize(at: installFolder) == 10_240", fixture)
        self.assertIn("4 * 1024 * 1024 * 1024 + 10_240", fixture)
        self.assertIn("createSymbolicLink", fixture)


if __name__ == "__main__":
    unittest.main()
