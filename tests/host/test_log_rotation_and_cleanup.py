"""The Wine log is rotated between sessions; a stuck cleanup asks for a restart."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class WineLogRotationTests(unittest.TestCase):
    def test_rotated_before_the_session_offset_is_taken(self):
        body = COORDINATOR[COORDINATOR.index("private func captureWineLogStart()"):]
        body = body[:body.index("\n    }\n")]
        self.assertLess(body.index("Self.rotateWineLogIfLarge(url)"), body.index("attributesOfItem"))

    def test_only_rotated_while_no_wine_runs_and_one_previous_is_kept(self):
        body = COORDINATOR[COORDINATOR.index("static func rotateWineLogIfLarge("):]
        body = body[:body.index("\n    }\n")]
        self.assertIn("guard !ideck_wineprocess_running(), !ideck_wineserver_running()", body)
        self.assertIn('"madeira-log.previous.txt"', body)
        self.assertIn("static let wineLogRotateBytes: Int64 = 24 << 20", COORDINATOR)


class SessionCleanupTests(unittest.TestCase):
    def test_waits_twenty_seconds_with_a_status_then_asks_for_a_restart(self):
        body = COORDINATOR[COORDINATOR.index("private func previousWineSessionStillFinishing()"):]
        body = body[:body.index("\n    }\n")]
        self.assertIn('setWindowsStatus("Waiting for the previous Windows session to finish…")', body)
        self.assertIn("waitForSessionCleanup(timeout: 20)", body)
        self.assertEqual(body.count("setWindowsStatus(Self.cleanupStuckMessage)"), 2)
        self.assertNotIn("Retry after it finishes", COORDINATOR)
        self.assertNotIn("native Wine session cleanup is still in progress", COORDINATOR)

    def test_messages_are_translated(self):
        table = (ROOT / "iDeck/Localization.swift").read_text()
        self.assertIn('"Waiting for the previous Windows session to finish…": ["pt":', table)
        self.assertIn('"Execution Error: the previous Windows session did not finish closing.', table)


if __name__ == "__main__":
    unittest.main()
