import unittest
from pathlib import Path

from support import ROOT, repo_text

MADEIRA_EA = ("EAAPI.swift", "EADownloader.swift", "EAFormats.swift", "EALicense.swift", "EAService.swift")


class EAAndUbisoftTests(unittest.TestCase):
    def test_madeira_swiftea_is_vendored_and_registered(self):
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        for name in MADEIRA_EA:
            with self.subTest(name=name):
                self.assertTrue((ROOT / "iDeck/Vendor/Madeira/SwiftEA" / name).exists())
                self.assertIn(f"/* {name} in Sources */", project)
        for name in ("EALibrary.swift", "EASignIn.swift", "EAGlue.swift", "UbisoftLibrary.swift"):
            self.assertIn(f"/* {name} in Sources */", project)

    def test_ea_library_is_adapted_without_madeira_library_model(self):
        library = repo_text("iDeck/EALibrary.swift")
        self.assertNotIn("LibraryModel", library)
        self.assertNotIn("LibraryEntry", library)
        self.assertIn("func prepareLaunch(offerID id: String", library)
        self.assertIn("EARegistry.write(values, prefix: MadeiraDock.prefix)", library)

    def test_ea_launch_and_environment(self):
        view = repo_text("iDeck/MainView.swift")
        self.assertIn("try await eaLibrary.prepareLaunch(offerID: game.offerID", view)
        self.assertIn('if !gameID.hasPrefix("ea:") { EALibrary.clearEnvironment() }', repo_text("iDeck/SystemCoordinator.swift"))

    def test_registry_lines_follow_wine(self):
        glue = repo_text("iDeck/MadeiraDock/EAGlue.swift")
        self.assertIn('"Software\\\\Wow6432Node\\\\" + key.dropFirst("Software\\\\".count)', glue)
        self.assertIn('return name + String(format: "=dword:%08x", number)', glue)

    def test_ubisoft_installs_through_its_client(self):
        ubisoft = repo_text("iDeck/UbisoftLibrary.swift")
        self.assertIn('https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe', ubisoft)
        self.assertIn('http.url?.host?.hasSuffix(".ubi.com") == true', ubisoft)
        self.assertIn('Software\\\\Ubisoft\\\\Launcher\\\\Installs\\\\', ubisoft)
        self.assertIn('profile.arguments = "uplay://launch/\\(game.id)/0"', repo_text("iDeck/MainView.swift"))

    def test_irelay_endpoints_know_ea_and_ubisoft(self):
        service = repo_text("iDeck/IRelayDeviceService.swift")
        for text in ('case "ea":', 'case "ubisoft":', '"ea": ["signedIn"', '"ubisoft": ["clientInstalled"'):
            self.assertIn(text, service)


if __name__ == "__main__":
    unittest.main()
