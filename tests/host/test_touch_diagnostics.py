import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TouchDiagnosticsTests(unittest.TestCase):
    def test_taps_logged_and_reported(self):
        touch = (ROOT / "iDeck/TouchMouseView.swift").read_text()
        self.assertIn('AppLog.record("[touch] tap at', touch)
        self.assertIn("WindowsRendererView.touchMappingSummary", touch)
        report = (ROOT / "iDeck/BugReportView.swift").read_text()
        self.assertIn('"[touch] tap", "[memory] session"', report)
        self.assertIn("diagnostics.contains(where: lower.contains)", report)


if __name__ == "__main__":
    unittest.main()
