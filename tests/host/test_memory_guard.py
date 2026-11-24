import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = (ROOT / "iDeck/SessionCompatibility.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
ENV = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
APP = (ROOT / "iDeck/iDeckApp.swift").read_text()


class MemoryGuardTests(unittest.TestCase):
    def test_sampler_keeps_game_and_lowest_available_every_5_seconds(self):
        self.assertIn("Timer(timeInterval: 5, repeats: true)", COORD)
        self.assertIn("defaults.set(available, forKey: MemoryGuard.lowestAvailableKey)", COORD)
        self.assertIn("if tick % 6 == 0 { log(\"sample\", nil, nil) }", COORD)
        self.assertIn("defaults.removeObject(forKey: MemoryGuard.sessionGameKey)", COORD)

    def test_app_restart_records_memory_stop_before_outcome_is_overwritten(self):
        check = APP.index("MemoryGuard.checkAfterAppRestart(sessionWasRunning: SystemCoordinator.SessionOutcome.isRunning)")
        self.assertLess(check, APP.index("SystemCoordinator.SessionOutcome.noteAppRestart()"))
        self.assertIn("static let lowMemoryMiB = 512", GUARD)

    def test_lighter_settings_and_launch_hold(self):
        self.assertIn("MemoryGuard.lighten(profile.id)", ENV)
        self.assertIn("MemoryGuard.holdMessage(id)", COORD)
        self.assertIn('MemoryGuard.holdMessage("steam:\\(game.appID)")', COORD)
        self.assertIn("static let blockAfterKills = 2", GUARD)
        self.assertIn("static let overrideSeconds: TimeInterval = 180", GUARD)

    def test_clean_exit_clears(self):
        self.assertIn("MemoryGuard.noteCleanExit(game)", GUARD)


if __name__ == "__main__":
    unittest.main()
