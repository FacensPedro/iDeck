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

    def test_ubisoft_launch_does_not_require_windows_launcher(self):
        view = repo_text("iDeck/MainView.swift")
        settings = repo_text("iDeck/SettingsView.swift")
        ubisoft = repo_text("iDeck/UbisoftLibrary.swift")
        self.assertIn("UbisoftLibrary.gameExecutable(game)", view)
        self.assertNotIn('profile.arguments = "uplay://launch/', view)
        self.assertNotIn('Button(tr("Run Windows installer"))', settings)
        self.assertNotIn('Button(ubisoftDownloading', settings)
        self.assertIn('tr("No launcher required")', settings)
        self.assertIn('Software\\\\Ubisoft\\\\Launcher\\\\Installs\\\\', ubisoft)

    def test_irelay_endpoints_know_ea_and_ubisoft(self):
        service = repo_text("iDeck/IRelayDeviceService.swift")
        for text in ('case "ea":', 'case "ubisoft":', '"ea": ["signedIn"', '"ubisoft": ["clientInstalled"'):
            self.assertIn(text, service)


if __name__ == "__main__":
    unittest.main()
