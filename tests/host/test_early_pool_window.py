import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class EarlyPoolWindowTests(unittest.TestCase):
    def test_early_pool_keeps_256mb(self):
        coord = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn("static let earlyExeWindowMB = 256", coord)
        block = coord[coord.index("iDeck opened by StikDebug: prepare Wine's pool now"):]
        self.assertLess(block.index("StikJITHelper.exeWindowAutoMB = Self.earlyExeWindowMB"),
                        block.index("MadeiraWinePool.prepare()"))
        self.assertIn("SystemCoordinator.earlyPoolExeWindowMB", (ROOT / "iDeck/WindowsEnvironment.swift").read_text())

    def test_report(self):
        view = (ROOT / "iDeck/BugReportView.swift").read_text()
        self.assertIn('"steamservice.dll"', view)
        self.assertIn('poolSetting > 0 ? "\\(poolSetting) MB" : "automatic"', view)


if __name__ == "__main__":
    unittest.main()
