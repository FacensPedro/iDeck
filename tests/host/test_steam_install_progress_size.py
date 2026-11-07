import unittest
from pathlib import Path

from support import ROOT, repo_text
class SteamInstallProgressAccountingTests(unittest.TestCase):
    def test_portuguese_and_spanish_install_labels(self):
        localization = repo_text("iDeck/Localization.swift")
        self.assertIn('"Installed: %@": ["pt": "Instalado: %@", "es": "Instalado: %@"]', localization)
        self.assertIn('"Installing %d%%": ["pt": "Instalando %d%%", "es": "Instalando %d%%"]', localization)
        self.assertNotIn('"Already on device: %@"', localization)
        self.assertNotIn('"Downloading %d%%"', localization)

    def test_swift_host_suite_checks_real_install_size(self):
        fixture = repo_text("tests/host/SteamInstallLaunchPathTests.swift")
        self.assertIn("SteamInstallFiles.logicalInstalledSize(at: installFolder) == 10_240", fixture)
        self.assertIn("4 * 1024 * 1024 * 1024 + 10_240", fixture)
        self.assertIn("createSymbolicLink", fixture)


if __name__ == "__main__":
    unittest.main()
