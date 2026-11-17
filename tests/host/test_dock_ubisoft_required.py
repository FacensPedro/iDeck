import pathlib
import unittest

SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck/Vendor/Madeira/DockInstallers.swift").read_text()


class DockUbisoftRequiredTests(unittest.TestCase):
    def test_black_flag_keeps_ubisoft_connect(self):
        self.assertIn("242050, // Assassin's Creed IV Black Flag", SRC)
        self.assertIn("if !ubisoft.isEmpty, Self.requiresUbisoftConnect(game, drive: drive) {", SRC)

    def test_any_ubisoft_loader_requires_launcher(self):
        for dll in ("uplay_r1_loader.dll", "uplay_r1_loader64.dll", "upc_r2_loader64.dll"):
            self.assertIn(f'"{dll}"', SRC)

    def test_launcher_runs_lite(self):
        self.assertIn("enum UbisoftConnectLite", SRC)
        self.assertIn('("overlay", "enabled", "false")', SRC)
        self.assertIn("Ubisoft Game Launcher", SRC)
        self.assertIn("let users = UbisoftConnectLite.apply(drive: drive)", SRC)
        self.assertIn("} else if !ubisoft.isEmpty {", SRC)


if __name__ == "__main__":
    unittest.main()
