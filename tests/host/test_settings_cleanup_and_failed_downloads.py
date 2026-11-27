"""2.13.3: game settings save themselves, a few notes go, failed downloads are removed."""
from __future__ import annotations

import split_sources  # noqa: F401  (iDeck 3.0 split files)
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VIEW = (ROOT / "iDeck" / "MainView.swift").read_text()
SETTINGS = (ROOT / "iDeck" / "SettingsView.swift").read_text()
LOC = (ROOT / "iDeck" / "Localization.swift").read_text()


def text(name: str) -> str:
    return (ROOT / "iDeck" / name).read_text()


class GameSettingsTests(unittest.TestCase):
    def test_saved_as_they_change(self):
        self.assertEqual(VIEW.count(".onChange(of: profile) { _, changed in library.save(changed) }"), 3)
        self.assertNotIn('Label(tr("Save"), systemImage: "checkmark")', VIEW)

    def test_no_directx_note_and_automatic_cores(self):
        self.assertNotIn("chosen automatically for each game", VIEW + LOC)
        self.assertIn('profile.cpuCount == 0 ? tr("Automatic")', VIEW)


class NotesRemovedTests(unittest.TestCase):
    def test_settings_notes(self):
        self.assertNotIn("Notifications are turned off for iDeck in iOS Settings.", SETTINGS + LOC)
        self.assertNotIn('settingsSection(title: tr("Version"))', SETTINGS)
        self.assertNotIn("An updated iDeck IPA must be signed", SETTINGS)

    def test_no_paused_text(self):
        self.assertNotIn('tr("Download paused")', VIEW + text("BackgroundDownloads.swift"))


class FailedDownloadsRemovedTests(unittest.TestCase):
    def test_every_store(self):
        self.assertIn("removePartialInstall(id)\n                    EALog.event(\"[ea-download] failed id=", text("EALibrary.swift"))
        self.assertIn('[epic-download] failed app=\\(app): partial files removed', text("EpicLibrary.swift"))
        self.assertIn("partial files removed", text("GOGLibrary.swift"))
        self.assertIn("            if !wasInstalled {", text("SteamManager.swift"))
        self.assertIn("// A failed install is removed, as Stop does", text("UbisoftLibrary.swift"))


if __name__ == "__main__":
    unittest.main()
