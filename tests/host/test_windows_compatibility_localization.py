import unittest
from pathlib import Path

from support import ROOT, repo_text
SETTINGS = repo_text("iDeck/SettingsView.swift")
COORDINATOR = repo_text("iDeck/SystemCoordinator.swift")
LOCALIZATION = repo_text("iDeck/Localization.swift")
ENVIRONMENT = repo_text("iDeck/WindowsEnvironment.swift")


class AutomaticWindowsRuntimeSettingsTests(unittest.TestCase):
    def test_manual_panel_is_removed(self):
        self.assertNotIn('settingsSection(title: tr("Windows compatibility"))', SETTINGS)
        self.assertNotIn("windowsCompatibilityContent", SETTINGS)
        self.assertNotIn("vcRuntimeFolderStatus", SETTINGS)

    def test_auto_setup_remains(self):
        self.assertIn("prepareVisualCRuntimeIfNeeded(prefix:", COORDINATOR)
        self.assertIn("VisualCRuntimeBootstrap.extractAndInstall(", COORDINATOR)
        self.assertIn('"Install Microsoft Visual C++?"', LOCALIZATION)

    def test_default_wine_dll_loading(self):
        self.assertNotIn('setenv("WINEDLLOVERRIDES"', ENVIRONMENT)


if __name__ == "__main__":
    unittest.main()
