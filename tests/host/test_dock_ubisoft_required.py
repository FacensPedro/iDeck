import pathlib
import unittest

SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck/Vendor/Madeira/DockInstallers.swift").read_text()


class DockUbisoftRequiredTests(unittest.TestCase):
    def test_black_flag_keeps_ubisoft_connect(self):
        self.assertIn("242050, // Assassin's Creed IV Black Flag", SRC)
        self.assertIn("if !ubisoft.isEmpty, Self.requiresUbisoftConnect(app) {", SRC)
        self.assertIn("} else if !ubisoft.isEmpty {", SRC)


if __name__ == "__main__":
    unittest.main()
