import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCANNER = (ROOT / "iDeck/BugReportView.swift").read_text(encoding="utf-8")
STEAM = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
GOV = (ROOT / "iDeck/ResourceGovernor.swift").read_text(encoding="utf-8")
DOWN = (ROOT / "iDeck/SwiftSteam/Content/DepotDownloader.swift").read_text(encoding="utf-8")
START = (ROOT / "iDeck/iDeckApp.swift").read_text(encoding="utf-8")


class SteamMemoryDiagnosticsTests(unittest.TestCase):
    def test_zero_missing_telemetry_is_not_an_error(self):
        self.assertIn(r"\b(error|errors|failed|failures|missing)\s*[=:]\s*0\b", SCANNER)
        self.assertIn("zeroCount.stringByReplacingMatches(in: lower", SCANNER)
        self.assertIn("errors.contains(where: actionable.contains)", SCANNER)
        self.assertIn("failures.contains(where: actionable.contains)", SCANNER)
        self.assertIn('"pressure critical"', SCANNER)

    def test_memory_pressure_logs_foreground_and_active_installs(self):
        self.assertIn("SteamOwnedGamesModel.shared.installingApps.count", GOV)
        self.assertIn("app active: ", GOV)
        self.assertIn("Steam installs: ", GOV)
        self.assertIn("Self.footprintMiB()", GOV)
        self.assertIn("Self.availableMiB()", GOV)

    def test_steam_resume_uses_two_bounded_16mib_readers(self):
        self.assertIn("let blockSize = 16 << 20", DOWN)
        self.assertIn("let width = 2", DOWN)
        self.assertIn("let journals = try plans.indices.map", DOWN)
        self.assertIn("results[i] = Data(digest) == chunk.sha", DOWN)

    def test_resume_reports_all_chunks_not_only_failed_existing_file_checks(self):
        # Chunks in brand-new files never enter checkExisting's hash result
        # array. The remaining queue must be counted after filtering.
        self.assertIn('journal-resume=', DOWN)
        self.assertIn('[steam-depot] resume checked app=', DOWN)
        self.assertIn(r'to-fetch-chunks=\\(work.reduce(0) { $0 + $1.count })', DOWN)
        self.assertNotIn(r'to-fetch-chunks=\\(bad.reduce(0)', DOWN)

    def test_resume_checks_available_disk_after_existing_chunk_verification(self):
        # ftruncate sets logical length before the data arrives. Compare free
        # space to verified pending bytes, not to the sparse file's length.
        start = DOWN.index('SteamLog.event("[steam-depot] install begin')
        verified = DOWN.index('try await checkExisting(plans: plans,', start)
        pending = DOWN.index('var pendingUncompressed: UInt64 = 0', verified)
        free = DOWN.index('if pendingUncompressed > 0, let free = installURL.freeSpace', pending)
        relay = DOWN.index(r'if !work.allSatisfy(\\.isEmpty), let pc = IRelayClient.configured()', free)
        self.assertLess(verified, pending)
        self.assertLess(pending, free)
        self.assertLess(free, relay)
        self.assertIn('insufficientDiskSpace(needed: pendingUncompressed', DOWN)

    def test_diagnostics_identify_game_before_start(self):
        self.assertIn('forKey: "diagnostics.lastGame"', STEAM)
        self.assertIn('forKey: "diagnostics.lastLauncher"', STEAM)
        self.assertIn('UserDefaults.standard.set("Steam"', STEAM)
        self.assertIn('[steam-install] started app=', STEAM)

    def test_unexpected_restart_keeps_installed_files_and_logs_previous_install(self):
        self.assertIn('forKey: "diagnostics.installInFlight"', STEAM)
        self.assertIn('UserDefaults.standard.removeObject(forKey: "diagnostics.installInFlight")', STEAM)
        self.assertIn('diagnostics.string(forKey: "diagnostics.installInFlight")', START)
        self.assertIn('[startup] warning: previous Steam installation did not finish normally', START)
        self.assertNotIn("SteamInstallFiles.delete", START)


if __name__ == "__main__":
    unittest.main()
