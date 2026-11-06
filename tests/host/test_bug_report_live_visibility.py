import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUGS = (ROOT / "iDeck/BugReportView.swift").read_text(encoding="utf-8")
SERVICE = (ROOT / "iDeck/IRelayDeviceService.swift").read_text(encoding="utf-8")

class BugReportLiveVisibilityTests(unittest.TestCase):
    def test_all_detected_bugs_are_expanded_by_default(self):
        self.assertIn("@State private var bugsOpen = true", BUGS)
        self.assertIn("@State private var jitOpen = true", BUGS)
        self.assertIn("ForEach(gameIssues) { issue in issueRow(issue) }", BUGS)
        self.assertIn("if jitOpen { ForEach(jitIssues) { issue in issueRow(issue) } }", BUGS)

    def test_jit_only_errors_do_not_show_an_empty_general_errors_section(self):
        self.assertIn("let gameIssues = model.issues.filter { $0.source != .jit }", BUGS)
        self.assertIn("model.isScanning && gameIssues.isEmpty", BUGS)
        self.assertIn("} else if gameIssues.isEmpty {", BUGS)
        self.assertIn('Text(tr("Bugs found") + (gameIssues.isEmpty ?', BUGS)
        self.assertNotIn("model.issues.isEmpty ? \"\" : \" (\\(model.issues.count))\"", BUGS)

    def test_bugs_refresh_while_visible_and_cancel_when_hidden(self):
        self.assertIn("while !Task.isCancelled {", BUGS)
        self.assertIn("Task.sleep(nanoseconds: 5_000_000_000)", BUGS)
        self.assertIn("guard !Task.isCancelled else { break }", BUGS)
        self.assertIn(".task {", BUGS)
        self.assertIn("await model.scan()", BUGS)

    def test_diagnostics_keep_long_wine_errors_and_warning_patterns(self):
        self.assertIn("let original = raw.trimmingCharacters", BUGS)
        self.assertIn("String(original.prefix(1200))", BUGS)
        self.assertIn("String(original.suffix(750))", BUGS)
        for marker in ("warning", "warn:", "missing", "stale", "mprotect", "invalid"):
            self.assertIn('"' + marker + '"', BUGS)

    def test_clear_does_not_resurrect_errors_from_an_inflight_scan(self):
        self.assertIn("private var scanGeneration = 0", BUGS)
        self.assertIn("let generation = scanGeneration", BUGS)
        self.assertIn("guard generation == scanGeneration, !Task.isCancelled else { return }", BUGS)
        self.assertIn("scanGeneration += 1", BUGS)
        self.assertIn("downloadsOrTransfersActive", BUGS)

    def test_both_persistent_logs_are_scanned_and_reports_retain_device_identity(self):
        self.assertIn('appendingPathComponent("iDeck-app-log.txt"', BUGS)
        self.assertIn('appendingPathComponent("madeira-log.txt"', BUGS)
        self.assertIn("LogIssueScanner.scan(appText", BUGS)
        self.assertIn("LogIssueScanner.scan(text, source: .wine", BUGS)
        self.assertIn("Self.gameContext", BUGS)
        self.assertIn("Self.hardwareSummary", BUGS)
        self.assertIn("LogIssueScanner.scan(wine, source: .wine", SERVICE)

if __name__ == "__main__":
    unittest.main()
