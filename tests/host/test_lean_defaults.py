import unittest

from support import repo_text


class LeanDefaultsTests(unittest.TestCase):
    def test_logs_are_detailed_without_the_slow_profilers(self):
        environment = repo_text("iDeck/WindowsEnvironment.swift")
        self.assertIn('setenv("WINEDEBUG", "err+all", 1)', environment)
        self.assertIn('setenv("MADEIRA_DEBUG_VERBOSE", "1", 1)', environment)
        # The PC sampler and the JIT dump stay off: they are what slowed games down.
        self.assertIn('setenv("MADEIRA_QUIET", "1", 1)', environment)
        self.assertIn('setenv("MADEIRA_JIT_DUMP", "0", 1)', environment)
        self.assertNotIn("diagnostics.detailed", environment)

    def test_the_detailed_diagnostics_switch_is_gone(self):
        report = repo_text("iDeck/BugReportView.swift")
        self.assertNotIn("Detailed diagnostics", report)
        self.assertNotIn("diagnostics.detailed", report)
        for line in ('"Memory+: increased limit', '"JIT: method', '"Windows runtime: x64', '"Build: commit'):
            self.assertIn(line, report)

    def test_gog_fetches_a_window_of_chunks_per_file(self):
        gog = repo_text("iDeck/GOGContentSystem.swift")
        self.assertIn("for _ in 0..<DownloadSpeed.gogChunksPerFile { add() }", gog)
        self.assertIn("while let data = ready.removeValue(forKey: written) {", gog)
        self.assertIn("for _ in 0..<DownloadSpeed.gogFiles { add() }", gog)

    def test_steam_uses_the_shared_chunk_width(self):
        depot = repo_text("iDeck/SwiftSteam/Content/DepotDownloader.swift")
        self.assertIn("private let maxConcurrentChunks = DownloadSpeed.steamChunks", depot)
        self.assertIn("config.httpMaximumConnectionsPerHost = DownloadSpeed.steamConnections", depot)

    def test_an_unchanged_dock_report_is_not_parsed_again(self):
        dock = repo_text("iDeck/Vendor/Madeira/MadeiraDock.swift")
        self.assertIn("last.0 == stamp.0, last.1 == stamp.1 { return lastReport }", dock)
        self.assertIn("lastReportStamp = nil", dock)

    def test_new_games_default_to_30_fps(self):
        self.assertIn('var fpsLimit: String = "30"', repo_text("iDeck/WindowsLibraryModels.swift"))


if __name__ == "__main__":
    unittest.main()
