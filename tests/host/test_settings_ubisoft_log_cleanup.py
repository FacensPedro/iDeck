import unittest

from support import repo_text

SETTINGS = repo_text("iDeck/SettingsView.swift")
MAIN = repo_text("iDeck/MainView.swift")
UBISOFT = repo_text("iDeck/UbisoftLibrary.swift")
RELAY = repo_text("iDeck/IRelayClient.swift")
LOG = repo_text("iDeck/BugReportView.swift")


class SettingsUbisoftLogCleanupTests(unittest.TestCase):
    def test_ubisoft_games_start_without_the_launcher(self):
        self.assertNotIn("Install Ubisoft Connect in Settings", MAIN)
        self.assertNotIn(".disabled(!UbisoftLibrary.clientInstalled)", MAIN)
        self.assertIn("UbisoftLibrary.gameExecutable(game)", MAIN)
        self.assertIn("static func gameExecutable", UBISOFT)
        self.assertNotIn("nonisolated static func gameExecutable", UBISOFT)

    def test_ea_games_open_details_and_keep_download_actions(self):
        self.assertIn(".sheet(item: $selectedEAGame)", MAIN)
        self.assertIn("private struct EAGameDetailsSheet: View", MAIN)
        card = MAIN.split("private func eaCard(", 1)[1].split("/// Licence, registry", 1)[0]
        self.assertIn("selectedEAGame = game", card)
        self.assertIn("downloadCoverButton { eaLibrary.install(game.id) }", card)
        details = MAIN.split("private struct EAGameDetailsSheet: View", 1)[1].split("/// Epic game page.", 1)[0]
        self.assertIn("StoreGameDetailsView(", details)
        self.assertIn("ea.loadSize(game.id)", details)
        self.assertIn("ea.checkForUpdate(game.id)", details)
        self.assertIn("ea.repair(game.id)", details)

    def test_settings_rows_are_trimmed(self):
        self.assertNotIn('value: tr("Steam, GOG, Epic, EA, Ubisoft")', SETTINGS)
        overview = SETTINGS.split('tr("JIT active")', 1)[1].split("}", 1)[0]
        self.assertNotIn("Madeira-native", overview)
        self.assertIn('asset: "StoreBadgeGOG", assetPlain: true', SETTINGS)
        self.assertNotIn("Keep the PC and this iPad on the same network", RELAY)

    def test_graphics_page_keeps_advanced_choices_behind_a_link(self):
        page = SETTINGS.split("private var graphicsPage: some View", 1)[1].split("// MARK: Storage", 1)[0]
        self.assertIn('NavigationLink(tr("Advanced"))', page)
        self.assertLess(page.index('NavigationLink(tr("Advanced"))'), page.index("MadeiraGraphicsSettings()"))

    def test_log_times_use_device_time_zone(self):
        self.assertIn("formatter.timeZone = .current", LOG)


if __name__ == "__main__":
    unittest.main()
