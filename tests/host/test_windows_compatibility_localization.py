import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION = (ROOT / "iDeck/Localization.swift").read_text(encoding="utf-8")
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")

WINDOWS_KEYS = (
    "Windows compatibility",
    "Microsoft Visual C++ libraries",
    "Madeira can load legally obtained x64 Visual C++ DLLs from the app's Documents/vcruntime folder. The application does not download Microsoft DLLs. Restart iDeck before launching a game after changing them.",
    "Prepare Visual C++ folder",
    "Could not locate the app's Documents folder.",
    "Folder ready: Files > On My iPad > iDeck > vcruntime.",
    "Could not prepare the Visual C++ folder.",
)

class WindowsCompatibilityLocalizationTests(unittest.TestCase):
    def test_portuguese_and_spanish_translations_are_complete(self):
        for key in WINDOWS_KEYS:
            with self.subTest(key=key):
                pattern = re.escape('"' + key + '":') + r' \["pt": "([^"]+)", "es": "([^"]+)"\]'
                match = re.search(pattern, LOCALIZATION)
                self.assertIsNotNone(match)
                self.assertNotEqual(match.group(1), key)
                self.assertNotEqual(match.group(2), key)
                self.assertEqual(LOCALIZATION.count('"' + key + '":'), 1)

    def test_section_and_button_use_translation_function(self):
        self.assertIn('settingsSection(title: tr("Windows compatibility"))', SETTINGS)
        self.assertIn('Text(tr("Microsoft Visual C++ libraries"))', SETTINGS)
        self.assertIn('actionButton(title: tr("Prepare Visual C++ folder")', SETTINGS)
        self.assertIn('Text(tr(vcRuntimeFolderStatus))', SETTINGS)

    def test_feedback_stores_translation_keys_not_translated_values(self):
        for key in WINDOWS_KEYS[-3:]:
            self.assertIn('vcRuntimeFolderStatus = "' + key + '"', SETTINGS)
            self.assertNotIn('vcRuntimeFolderStatus = tr("' + key + '")', SETTINGS)

if __name__ == "__main__":
    unittest.main()
