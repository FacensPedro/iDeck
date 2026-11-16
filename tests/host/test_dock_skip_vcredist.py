import pathlib, unittest
SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck/Vendor/Madeira/DockInstallers.swift").read_text()
class DockSkipsVCRedist(unittest.TestCase):
    def test_vcredist_left_out(self):
        self.assertIn("func isVCRedist(", SRC)
        self.assertIn("pending.removeAll { Self.isVCRedist($0) }", SRC)
        self.assertIn("Visual C++ redistributables skipped", SRC)
