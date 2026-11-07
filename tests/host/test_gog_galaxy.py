import unittest

from support import ROOT, repo_text

GALAXY = ("GalaxyListener.swift", "GalaxyService.swift", "GalaxySupport.swift", "GalaxyWire.swift")


class GOGGalaxyTests(unittest.TestCase):
    def test_galaxy_service_is_vendored_and_built(self):
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        for name in GALAXY + ("GOGGalaxy.swift",):
            self.assertIn(f"/* {name} in Sources */", project)
        for name in GALAXY:
            self.assertTrue((ROOT / "iDeck/Vendor/Madeira/SwiftGOG/Galaxy" / name).exists())
        self.assertIn("/* madeira-galaxy-service.exe in Resources */", project)
        exe = (ROOT / "iDeck/Resources/Galaxy/madeira-galaxy-service.exe").read_bytes()
        self.assertEqual(exe[:2], b"MZ")
        self.assertTrue((ROOT / "build/gog-galaxy-service/main.c").exists())
        self.assertTrue((ROOT / "LICENSES/Playport-NOTICE.txt").exists())

    def test_per_game_token_comes_from_ideck_sign_in(self):
        service = repo_text("iDeck/Vendor/Madeira/SwiftGOG/Galaxy/GalaxyService.swift")
        self.assertIn("struct IDeckGalaxyTokens: GalaxyTokenSource", service)
        self.assertIn('.init(name: "without_new_session", value: "1")', service)
        self.assertNotIn("extension GOGAPI: GalaxyTokenSource", service)
        self.assertIn("static func galaxyClient(gameID: Int, tokens: GOGTokens)", repo_text("iDeck/GOGContentSystem.swift"))

    def test_service_registered_in_prefix_and_lifecycle(self):
        glue = repo_text("iDeck/GOGGalaxy.swift")
        self.assertIn('static let serviceKey = "System\\\\ControlSet001\\\\Services\\\\GalaxyCommunication"', glue)
        self.assertIn("EARegistry.write(values, prefix: drive.deletingLastPathComponent())", glue)
        self.assertIn('name: "Type", data: .dword(0x10)', glue)
        self.assertIn("guard wineserver_is_running() == 0, wine_process_is_running() == 0", glue)
        view = repo_text("iDeck/MainView.swift")
        self.assertIn("await GOGGalaxy.shared.prepare(gameID: game.gameID, drive: EpicLibrary.drive)", view)
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertEqual(coordinator.count("GOGGalaxy.shared.stop()"), 2)


if __name__ == "__main__":
    unittest.main()
