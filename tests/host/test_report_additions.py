"""Bug report additions: .txt export, session outcome, prerequisites, crash location."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class ReportAdditionsTests(unittest.TestCase):
    def test_report_copied_as_text_file(self):
        self.assertIn('try WineLogClipboard.copyText(report(for: issues), named: "iDeck-bug-report.txt")', REPORT)
        self.assertIn("static func copyText(_ text: String, named name: String) throws {",
                      (ROOT / "iDeck/WineLogClipboard.swift").read_text())

    def test_session_outcome_recorded_and_reported(self):
        for line in ("SessionOutcome.began()", "SessionOutcome.status(status)",
                     'SessionOutcome.ended("closed with the X button")'):
            self.assertIn(line, COORDINATOR)
        self.assertIn("SystemCoordinator.SessionOutcome.noteAppRestart()", (ROOT / "iDeck/iDeckApp.swift").read_text())
        self.assertIn('" | last stage reached: "', REPORT)

    def test_prerequisites_per_game(self):
        installers = (ROOT / "iDeck/Vendor/Madeira/DockInstallers.swift").read_text()
        self.assertIn("forKey: DockInstallScripts.prerequisitesKey)", installers)
        self.assertIn('"Steam prerequisites (last run): "', REPORT)

    def test_crash_location_patterns_match_real_lines(self):
        self.assertIn('lines.append("Crash location: " + crashLocation)', REPORT)
        loaded = re.compile(r'Loaded L"([^"]+)" at ([0-9A-Fa-f]{6,16})')
        line = '0024:trace:loaddll:build_module Loaded L"C:\\\\windows\\\\system32\\\\kernelbase.dll" at 00000071FFC00000: builtin'
        self.assertEqual(loaded.search(line).group(2), "00000071FFC00000")
        self.assertIn(r'#"Loaded L"([^"]+)" at ([0-9A-Fa-f]{6,16})"#', REPORT)
        raise_ = re.compile(r"raise tid=\w+ code=([0-9a-fA-F]+) .*?addr=0x([0-9a-fA-F]+)")
        self.assertEqual(raise_.search("[exc-disp] raise tid=0030 code=c0000005 flags=0 addr=0x71ffd46730 pc=1").groups(),
                         ("c0000005", "71ffd46730"))
        self.assertIn(r'#"raise tid=\w+ code=([0-9a-fA-F]+) .*?addr=0x([0-9a-fA-F]+)"#', REPORT)


if __name__ == "__main__":
    unittest.main()
