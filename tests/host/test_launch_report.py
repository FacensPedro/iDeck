import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPAT = (ROOT / "iDeck/SessionCompatibility.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()


class LaunchReportTests(unittest.TestCase):
    def test_every_ending_is_recorded(self):
        self.assertIn("LaunchReport.begin(title: safeTitle)", COORD)
        self.assertIn("LaunchReport.finish(game: endedGame ?? \"unknown\", reason: reason, ntstatus: ntstatus, runtimeTrap: hostTrap)", COORD)
        self.assertIn('reason: "Steam: " + failure', COORD)
        self.assertIn("LaunchReport.finish(game: game, reason: reason, ntstatus: nil, runtimeTrap: false, appStopped: true)", COMPAT)

    def test_startup_time_from_the_first_image(self):
        self.assertIn("LaunchReport.firstImage()", SESSION)

    def test_classification_rules(self):
        body = COMPAT[COMPAT.index("static func classify("):COMPAT.index("static func finish(")]
        self.assertIn("if appStopped { return .iDeck }", body)
        self.assertIn("return sawImage ? .game : .runtime", body)
        self.assertIn("ntstatus == 0xC0000135 || ntstatus == 0xC000007B", body)
        self.assertLess(body.index("appStopped"), body.index("crashed"))

    def test_bug_report_lists_recent_launches(self):
        self.assertIn('lines.append("Recent launches (newest last):")', REPORT)


if __name__ == "__main__":
    unittest.main()
