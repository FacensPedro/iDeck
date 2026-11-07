import unittest
from pathlib import Path

from support import ROOT, repo_text
VIEW = repo_text("iDeck/MainView.swift")
PROJECT = repo_text("iDeck.xcodeproj/project.pbxproj")
SAVE = repo_text("iDeck/SessionControlsSheet.swift")
RELAY = repo_text("iDeck/IRelayClient.swift")
EPIC = repo_text("iDeck/EpicLibrary.swift")
GOG = repo_text("iDeck/GOGContentSystem.swift")
WORKFLOW = repo_text(".github/workflows/ios.yml")
NOTES = repo_text("RELEASE_NOTES.md")
SETTINGS = repo_text("iDeck/SettingsView.swift")
DOWNLOAD_SPEED = repo_text("iDeck/DownloadSpeed.swift")


class ReleaseInterfaceCDNTests(unittest.TestCase):
    def test_version_is_one_one_build_seventeen(self):
        self.assertNotIn("MARKETING_VERSION = 1.0.0;", PROJECT)
        self.assertEqual(PROJECT.count("MARKETING_VERSION = 1.1.0;"), 6)
        self.assertEqual(PROJECT.count("CURRENT_PROJECT_VERSION = 17;"), 6)

    def test_store_badges_no_longer_appear_with_game_titles(self):
        self.assertIn("private func cardTitle(_ title: String)", VIEW)
        self.assertNotIn("cardTitle(game.title, store:", VIEW)
        self.assertNotIn("StoreBadge(store: store).fixedSize()", VIEW)
        self.assertIn(".multilineTextAlignment(.center)", VIEW)
        self.assertIn(".frame(maxWidth: .infinity, alignment: .center)", VIEW)

    def test_long_game_titles_are_truncated_and_header_is_ideck(self):
        start = VIEW.index("    private func cardTitle(_ title: String)")
        end = VIEW.index("    private func cardActionLabel(", start)
        card = VIEW[start:end]
        self.assertIn(".lineLimit(1)", card)
        self.assertIn(".truncationMode(.tail)", card)
        self.assertIn(".accessibilityLabel(title)", card)
        top = VIEW.split("private var topBar: some View", 1)[1].split("private enum MixedLibraryEntry", 1)[0]
        self.assertIn('Text("iDeck")', top)
        self.assertNotIn('Image("IDeckLogo")', top)
        self.assertNotIn('Text(tr("Madeira"))', top)

    def test_legacy_steam_sizes_and_store_library_response(self):
        metadata = repo_text("iDeck/SwiftSteam/Library/SteamAppInfo.swift")
        device = repo_text("iDeck/IRelayDeviceService.swift")
        self.assertIn("func displaySizeForWindows(installedBytes: UInt64 = 0)", metadata)
        self.assertIn("case 22330: return 4.6", metadata)
        self.assertIn("case 489830: return 12.0", metadata)
        self.assertIn("size.isRequirement", device)
        self.assertIn('"requiredSpaceGB":', device)
        self.assertIn('"size": gog.installedSizes[game.id].flatMap', device)
        self.assertIn("steamLibrary.installedSizes[game.appID]", VIEW)
        self.assertIn('tr("Minimum required space: %@", text)', VIEW)

    def test_auto_save_default_remains_off(self):
        self.assertIn('@AppStorage(SteamCloudAutoSave.key) private var autoSave = false', SAVE)
        self.assertIn('@AppStorage(SteamCloudAutoSave.key) private var autoSaveEnabled = false', VIEW)

    def test_download_speed_acceleration_is_removed_from_ideck(self):
        self.assertNotIn("Unlimited download speed", SETTINGS)
        self.assertNotIn("unlimitedDownloadSpeed", SETTINGS)
        self.assertNotIn("isUnlimited", DOWNLOAD_SPEED)
        self.assertIn("static let steamChunks = 8", DOWNLOAD_SPEED)
        self.assertIn("static let epicWindow = 8", DOWNLOAD_SPEED)

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
        self.assertNotIn("Madeira", NOTES)
        self.assertIn('TITLE="iDeck $TAG"', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
