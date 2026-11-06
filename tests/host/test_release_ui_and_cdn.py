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
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
DOWNLOAD_SPEED = (ROOT / "iDeck/DownloadSpeed.swift").read_text(encoding="utf-8")


class ReleaseInterfaceCDNTests(unittest.TestCase):
    def test_version_is_one_zero_twelve_build_thirteen(self):
        self.assertNotIn("MARKETING_VERSION = 1.0.0;", PROJECT)
        self.assertEqual(PROJECT.count("MARKETING_VERSION = 1.0.12;"), 6)
        self.assertEqual(PROJECT.count("CURRENT_PROJECT_VERSION = 13;"), 6)

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
        metadata = (ROOT / "iDeck/SwiftSteam/Library/SteamAppInfo.swift").read_text()
        device = (ROOT / "iDeck/IRelayDeviceService.swift").read_text()
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
