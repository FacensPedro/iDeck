import unittest
from pathlib import Path

COORD = (Path(__file__).resolve().parents[2] / "iDeck/SystemCoordinator.swift").read_text()


class EarlyJITPoolTests(unittest.TestCase):
    def test_pool_prepared_while_the_debugger_is_attached(self):
        block = COORD[COORD.index("iDeck opened by StikDebug: prepare Wine's pool now"):]
        block = block[:block.index("self.refreshJITStatus()")]
        self.assertIn("MadeiraWinePool.prepare()", block)
        self.assertIn("self.wineJITPreparationInFlight = true", block)
        self.assertIn("!ideck_wineprocess_running()", block)

    def test_launch_accepts_a_prepared_pool(self):
        self.assertIn("return ideck_wine_jit_pool_ready() || StikJITHelper.ready", COORD)


if __name__ == "__main__":
    unittest.main()
