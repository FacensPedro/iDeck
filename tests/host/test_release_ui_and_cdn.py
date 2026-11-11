import unittest
from pathlib import Path

from support import ROOT, repo_text
VIEW = repo_text("iDeck/MainView.swift")
PROJECT = repo_text("iDeck.xcodeproj/project.pbxproj")
SAVE = repo_text("iDeck/SessionControlsSheet.swift")
EPIC = repo_text("iDeck/EpicLibrary.swift")
GOG = repo_text("iDeck/GOGContentSystem.swift")
WORKFLOW = repo_text(".github/workflows/ios.yml")
NOTES = repo_text("RELEASE_NOTES.md")
SETTINGS = repo_text("iDeck/SettingsView.swift")
DOWNLOAD_SPEED = repo_text("iDeck/DownloadSpeed.swift")


class ReleaseInterfaceCDNTests(unittest.TestCase):
    def test_release_version_matches_project_and_build(self):
        import re

        requested = repo_text(".github/release-request.txt").strip()
        versions = re.findall(r"MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);", PROJECT)
        builds = re.findall(r"CURRENT_PROJECT_VERSION = ([0-9]+);", PROJECT)
        self.assertEqual(len(versions), 6)
        self.assertEqual(set(versions), {requested})
        self.assertEqual(len(builds), 6)
        self.assertEqual(len(set(builds)), 1)
        self.assertGreater(int(builds[0]), 0)
        self.assertIn(f"Updated the application version to {requested} (build {builds[0]}).", NOTES)

    def test_store_badges_no_longer_appear_with_game_titles(self):
        self.assertIn("private func cardTitle(_ title: String)", VIEW)
        self.assertNotIn("cardTitle(game.title, store:", VIEW)
        self.assertNotIn("StoreBadge(store: store).fixedSize()", VIEW)
        self.assertIn(".multilineTextAlignment(.center)", VIEW)
        self.assertIn(".frame(maxWidth: .infinity, alignment: .center)", VIEW)

    def test_long_game_titles_are_truncated_and_header_is_ideck(self):
        start = VIEW.index("    private func cardTitle(_ title: String)")
        end = VIEW.index("    private func downloadCoverButton(", start)
        card = VIEW[start:end]
        # Long names wrap to a second line; every title reserves two lines.
        self.assertIn(".lineLimit(2, reservesSpace: true)", card)
        self.assertNotIn(".truncationMode(.tail)", card)
        self.assertIn(".accessibilityLabel(title)", card)
        top = VIEW.split("private var topBar: some View", 1)[1].split("private enum MixedLibraryEntry", 1)[0]
        self.assertIn('Text("iDeck")', top)
        self.assertNotIn('Image("IDeckLogo")', top)
        self.assertNotIn('Text(tr("Madeira"))', top)

    def test_legacy_steam_sizes_and_store_library_response(self):
        metadata = repo_text("iDeck/SwiftSteam/Library/SteamAppInfo.swift")
        self.assertIn("func displaySizeForWindows(installedBytes: UInt64 = 0)", metadata)
        self.assertIn("case 22330: return 4.6", metadata)
        self.assertIn("case 489830: return 12.0", metadata)
        self.assertIn("steamLibrary.installedSizes[game.appID]", VIEW)
        self.assertIn('tr("Minimum required space: %@", text)', VIEW)

    def test_auto_save_default_remains_off(self):
        self.assertIn('@AppStorage(SteamCloudAutoSave.key) private var autoSave = false', SAVE)
        self.assertIn('@AppStorage(SteamCloudAutoSave.key) private var autoSaveEnabled = false', VIEW)

    def test_download_speed_acceleration_is_removed_from_ideck(self):
        self.assertNotIn("Unlimited download speed", SETTINGS)
        self.assertNotIn("unlimitedDownloadSpeed", SETTINGS)
        self.assertNotIn("isUnlimited", DOWNLOAD_SPEED)
        self.assertIn("static let steamChunks = 16", DOWNLOAD_SPEED)
        self.assertIn("static let epicWindow = 32", DOWNLOAD_SPEED)

    def test_release_notes_contain_no_authors_or_pull_links(self):
        self.assertIn("--notes-file RELEASE_NOTES.md", WORKFLOW)
        self.assertNotIn("github.com/", NOTES)
        self.assertNotIn("/pull/", NOTES)
        self.assertIn('TITLE="iDeck $TAG"', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
