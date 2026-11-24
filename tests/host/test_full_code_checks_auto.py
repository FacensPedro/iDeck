import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
APP = (ROOT / "iDeck/iDeckApp.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class FullCodeChecksAutoTests(unittest.TestCase):
    def test_marker_is_fex_redelivery_loop(self):
        self.assertIn('"unrecoverable host fault misdelivered to guest"', ENV)

    def test_checked_at_app_restart_before_the_outcome_is_overwritten(self):
        check = APP.index("FullCodeChecksAuto.checkAfterAppRestart(sessionWasRunning: SystemCoordinator.SessionOutcome.isRunning)")
        self.assertLess(check, APP.index("SystemCoordinator.SessionOutcome.noteAppRestart()"))

    def test_checked_at_session_end(self):
        self.assertIn("FullCodeChecksAuto.enable(endedGame)", COORD)

    def test_automatic_mode_becomes_full_checks(self):
        self.assertIn('if sessionCodeChecks == "Automatic", FullCodeChecksAuto.isOn(profile.id) {', ENV)
        self.assertIn('sessionCodeChecks = "Compatible"', ENV)
        self.assertIn('lines.append("env.FEX_SMCCHECKS = full")', ENV)
        self.assertIn("UserDefaults.standard.set(profile.id, forKey: FullCodeChecksAuto.lastGameKey)", ENV)


class PoolSafeRunShrinkTests(unittest.TestCase):
    def test_pool_shrinks_to_the_largest_safe_run(self):
        jit = (ROOT / "iDeck/MadeiraJIT/StikJITHelper.swift").read_text()
        self.assertIn("if pairA == nil && candidates.isEmpty, let roomiest = safeRuns.max(by: { $0.size < $1.size }) {", jit)
        self.assertIn("no safe run holds a %luMB pool — SHRINKING to %luMB at 0x%lx", jit)
        self.assertIn("if fit >= 256 << 20 {", jit)
        self.assertLess(jit.index("candidates = [roomiest.base]"), jit.index("guard let target = pairA?.base ?? candidates.first else {"))


if __name__ == "__main__":
    unittest.main()
