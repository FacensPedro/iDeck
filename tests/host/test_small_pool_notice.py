"""A shrunk JIT pool is only logged: the loading screen shows no pool size."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = (ROOT / "iDeck/MadeiraJIT/StikJITHelper.swift").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()


class SmallPoolNoticeTests(unittest.TestCase):
    def test_reset_each_launch_and_set_where_the_pool_shrinks(self):
        allocate = HELPER[HELPER.index("static func allocatePool("):]
        self.assertLess(allocate.index("smallPoolMB = 0"), allocate.index("SMALL JIT POOL"))

    def test_loading_screen_shows_no_pool_size(self):
        self.assertNotIn("StikJITHelper.smallPoolMB", SESSION)
        strings = (ROOT / "iDeck/Localization.swift").read_text()
        self.assertNotIn('"The pool is only %d MB."', strings)


if __name__ == "__main__":
    unittest.main()
