"""An EA game's bug report says what its licence was prepared for."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = (ROOT / "iDeck/EALibrary.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()


class EALicenceReportTests(unittest.TestCase):
    def test_launch_records_the_activation_facts_and_the_outcome(self):
        self.assertIn('nonisolated static let licenceFactsKey = "diagnostics.eaLicence"', LIBRARY)
        self.assertIn("nonisolated static func activationFacts(", LIBRARY)
        for outcome in ("licence not prepared", "licence request failed", "licence renewed", "licence kept"):
            self.assertIn(outcome, LIBRARY)
        # "request failed" is stored before the request, so a thrown error leaves it.
        self.assertLess(LIBRARY.index("licence request failed"), LIBRARY.index("try await EALicense.renew("))

    def test_only_ea_sessions_show_it(self):
        self.assertIn('.hasPrefix("EA"),', REPORT)
        self.assertIn('lines.append("EA licence: " + facts)', REPORT)
        self.assertIn('$0.line.contains("ActivationUI.exe")', REPORT)


if __name__ == "__main__":
    unittest.main()
