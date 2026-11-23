"""Rockstar Games Launcher installed after a Rockstar game; session buttons share one size (2.13.3)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COORD = (ROOT / "iDeck" / "SystemCoordinator.swift").read_text()
SESSION = (ROOT / "iDeck" / "GameSessionView.swift").read_text()


class RockstarLauncherTests(unittest.TestCase):
    def test_installed_after_steam_and_epic(self):
        self.assertIn("enum RockstarLauncher {", COORD)
        for name in ("SteamManager.swift", "EpicLibrary.swift"):
            self.assertIn("RockstarLauncher.installIfNeeded(gameFolder:", (ROOT / "iDeck" / name).read_text())

    def test_without_wine_and_registry(self):
        body = COORD[COORD.index("enum RockstarLauncher {"):]
        self.assertIn("ideck_nsis_extract(source.path, target.path", body)
        self.assertIn('name: "InstallFolder"', body)
        self.assertIn('static let installFolder = "Program Files/Rockstar Games/Launcher"', body)

    def test_not_a_store(self):
        start = COORD.index("enum StoreClient: String, CaseIterable {")
        self.assertNotIn("rockstar", COORD[start:start + 120].lower())


class SessionButtonTests(unittest.TestCase):
    def test_close_and_settings_match_minimize(self):
        for icon in ('"chevron.left.circle.fill"', '"xmark.circle.fill"', '"gearshape.fill"'):
            at = SESSION.index(icon)
            self.assertIn(".font(.system(size: 18))", SESSION[at:at + 120])


if __name__ == "__main__":
    unittest.main()
