"""A game's fixed-base exe is measured before the JIT pool is placed."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class ExecutableWindowTests(unittest.TestCase):
    def test_measured_before_every_pool_allocation(self):
        measure = ENV.index("Self.measureExecutableWindow(binary: binary, steamInstallDirectory: steamInstallDirectory)")
        self.assertLess(measure, ENV.index("if let failure = MadeiraWinePool.prepare() {"))
        body = ENV[ENV.index("static func measureExecutableWindow("):]
        body = body[:body.index("\n    }\n")]
        self.assertIn("StikJITHelper.fixedBaseWindowMB(in: folder)", body)
        self.assertIn("StikJITHelper.exeWindowAutoMB = need.mb", body)
        self.assertIn("StikJITHelper.exeWindowAutoMB = 0", body)
        # The Dock host and cmd.exe are never measured as the game.
        self.assertIn('name == "dockhost.exe" || name == "cmd.exe" ? nil', body)

    def test_dock_launches_pass_the_game_folder(self):
        start = COORDINATOR.index("private func continueDockSession(")
        body = COORDINATOR[start:COORDINATOR.index("DispatchQueue.main.async {", start)]
        self.assertIn("steamInstallDirectory: installsOnly ? nil : gameFolder", body)
        self.assertIn("SteamInstallFiles.installDirectoryName(appID: Int(game.appID), steamApps: steamApps)", body)


if __name__ == "__main__":
    unittest.main()
