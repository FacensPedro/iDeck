import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
LOCALIZATION = (ROOT / "iDeck/Localization.swift").read_text(encoding="utf-8")
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text(encoding="utf-8")


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
