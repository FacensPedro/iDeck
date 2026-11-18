import unittest
from pathlib import Path

from support import ROOT, repo_text

MADEIRA_EA = ("EAAPI.swift", "EADownloader.swift", "EAFormats.swift", "EALicense.swift", "EAService.swift")


class EAStoreTests(unittest.TestCase):
    def test_madeira_swiftea_is_vendored_and_registered(self):
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        for name in MADEIRA_EA:
            with self.subTest(name=name):
                self.assertTrue((ROOT / "iDeck/Vendor/Madeira/SwiftEA" / name).exists())
                self.assertIn(f"/* {name} in Sources */", project)
        for name in ("EALibrary.swift", "EASignIn.swift", "EAGlue.swift"):
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

    def test_ubisoft_store_uses_its_account_page_and_badge(self):
        self.assertTrue((ROOT / "iDeck/Assets.xcassets/StoreBadgeUbisoft.imageset/Ubisoft.png").is_file())
        self.assertIn("StoreClientCard(client: .ubisoft", repo_text("iDeck/MainView.swift"))
        self.assertIn("https://account.ubisoft.com/", repo_text("iDeck/SettingsView.swift"))


if __name__ == "__main__":
    unittest.main()
