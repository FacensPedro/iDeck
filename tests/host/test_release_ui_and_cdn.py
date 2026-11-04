import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "iDeck.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
SAVE = (ROOT / "iDeck/SessionControlsSheet.swift").read_text(encoding="utf-8")
RELAY = (ROOT / "iDeck/IRelayClient.swift").read_text(encoding="utf-8")
EPIC = (ROOT / "iDeck/EpicLibrary.swift").read_text(encoding="utf-8")
GOG = (ROOT / "iDeck/GOGContentSystem.swift").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")
NOTES = (ROOT / "RELEASE_NOTES.md").read_text(encoding="utf-8")


class ReleaseInterfaceCDNTests(unittest.TestCase):
    def test_version_is_one_zero_zero(self):
        self.assertNotIn("MARKETING_VERSION = 0.1.0;", PROJECT)
        self.assertIn("MARKETING_VERSION = 1.0.0;", PROJECT)

    def test_store_badges_no_longer_appear_with_game_titles(self):
        self.assertIn("private func cardTitle(_ title: String)", VIEW)
        self.assertNotIn("cardTitle(game.title, store:", VIEW)
        self.assertNotIn("StoreBadge(store: store).fixedSize()", VIEW)
        self.assertIn(".multilineTextAlignment(.center)", VIEW)
        self.assertIn(".frame(maxWidth: .infinity, alignment: .center)", VIEW)

    def test_auto_save_default_remains_off(self):
        self.assertIn('@AppStorage(SteamCloudAutoSave.key) private var autoSave = false', SAVE)
        self.assertIn('@AppStorage(SteamCloudAutoSave.key) private var autoSaveEnabled = false', VIEW)

    def test_irelay_reorders_only_official_cdn_origins(self):
        self.assertIn('relay.request("servers/rank"', RELAY)
        self.assertIn('return "https://', RELAY)
        self.assertIn('rankedCDNURLs(store: "epic"', EPIC)
        self.assertIn('rankedCDNURLs(store: "gog"', GOG)
        self.assertNotIn('store: "epic", urls: location.secrets', EPIC)

    def test_release_notes_contain_no_authors_or_pull_links(self):
        self.assertIn("--notes-file RELEASE_NOTES.md", WORKFLOW)
        self.assertNotIn("github.com/", NOTES)
        self.assertNotIn("/pull/", NOTES)


if __name__ == "__main__":
    unittest.main()
