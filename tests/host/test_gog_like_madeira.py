import json
import unittest

from support import ROOT, repo_text


class GOGLikeMadeiraTests(unittest.TestCase):
    """iDeck does what GOG Galaxy does around a game, as Madeira does, without the client."""

    def test_galaxy_client_is_not_installed(self):
        self.assertFalse((ROOT / "iDeck/GOGGalaxyApp.swift").exists())
        view = repo_text("iDeck/MainView.swift")
        self.assertNotIn("GOGGalaxyApp", view)
        self.assertIn("case visualCpp, wineMono, dock, jit, summary", view)
        self.assertNotIn("GOGGalaxyApp.swift", repo_text("iDeck.xcodeproj/project.pbxproj"))

    def test_install_script_is_kept_and_applied(self):
        content = repo_text("iDeck/GOGContentSystem.swift")
        self.assertIn('(item["flags"] as? [String] ?? []).contains("support")', content)
        self.assertIn("GOGInstallScript.isScriptName(name)", content)
        script = repo_text("iDeck/GOGInstallScript.swift")
        for marker in ('case "setregistry"', '"1207658924"', '"{app}"', "static func scripts(in folder: URL)"):
            self.assertIn(marker, script)
        services = repo_text("iDeck/GOGLaunchServices.swift")
        self.assertIn("EARegistry.write(values, prefix: drive.deletingLastPathComponent())", services)
        self.assertIn("guard wineserver_is_running() == 0, wine_process_is_running() == 0", services)
        self.assertIn("GOGLaunchServices.applyInstallScripts(folder: folder, drive: drive)", repo_text("iDeck/MainView.swift"))

    def test_redistributables_download_and_run_once(self):
        content = repo_text("iDeck/GOGContentSystem.swift")
        self.assertIn('"/dependencies/repository?generation=2"', content)
        self.assertIn("https://cdn.gog.com/content-system/v2/dependencies/meta/", content)
        self.assertIn("/open_link?generation=2&_version=2&path=/dependencies/store/", content)
        setup = repo_text("iDeck/GOGSetup.swift")
        self.assertIn('static let resultFolder = "C:\\\\ideck-games\\\\gog-setup"', setup)
        self.assertIn('">\\"\\(result)\\" echo %ERRORLEVEL%"', setup)
        for skipped in ("static let directX", "dotNetFramework", "visualCpp2015Plus"):
            self.assertIn(skipped, setup)
        view = repo_text("iDeck/MainView.swift")
        self.assertIn("GOGLaunchServices.setupBatch(gameID: game.gameID", view)
        self.assertIn('setup.arguments = "/c \\"\\(batch)\\""', view)
        self.assertIn("GOGLaunchServices.record(plan, folder: final)", repo_text("iDeck/GOGLibrary.swift"))

    def test_open_link_chunks_get_their_path_and_never_fail_the_game(self):
        content = repo_text("iDeck/GOGContentSystem.swift")
        self.assertIn('if !text.contains("{path}") {', content)
        self.assertIn('text += "{path}"', content)
        self.assertIn("$0.productID != Self.redistProduct", content)
        self.assertIn("[gog-setup] redistributables not downloaded", content)
        self.assertIn('note: "Not downloaded"', repo_text("iDeck/GOGLaunchServices.swift"))

    def test_offline_depot_is_not_installed(self):
        content = repo_text("iDeck/GOGContentSystem.swift")
        self.assertNotIn('manifest["offlineDepot"]', content)

    def test_sources_are_in_the_project(self):
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        for name in ("GOGInstallScript.swift", "GOGSetup.swift", "GOGLaunchServices.swift"):
            self.assertEqual(project.count(f"/* {name} in Sources */"), 2, name)


if __name__ == "__main__":
    unittest.main()
