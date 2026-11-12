"""A shrunk JIT pool is shown on the loading screen, not only in the log."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = (ROOT / "iDeck/MadeiraJIT/StikJITHelper.swift").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()


class SmallPoolNoticeTests(unittest.TestCase):
    def test_reset_each_launch_and_set_where_the_pool_shrinks(self):
        allocate = HELPER[HELPER.index("static func allocatePool("):]
        self.assertLess(allocate.index("smallPoolMB = 0"), allocate.index("SMALL JIT POOL"))
        self.assertIn("smallPoolMB = Int(best >> 20)", HELPER)
        self.assertIn("smallPoolMB = fit >> 20", HELPER)

    def test_loading_screen_shows_it_before_the_first_frame(self):
        self.assertIn("} else if !metrics.receivedNewFrames && StikJITHelper.smallPoolMB > 0 {", SESSION)
        self.assertIn('"The JIT pool is only %d MB this time', (ROOT / "iDeck/Localization.swift").read_text())


if __name__ == "__main__":
    unittest.main()
