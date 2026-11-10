import unittest
from pathlib import Path

from support import ROOT, repo_text
class FirstRunLaunchersContract(unittest.TestCase):
    def test_first_run_steps_are_real_and_resumable(self):
        swift = repo_text("iDeck/MainView.swift")
        for phrase in (
            "firstRunSetup.complete.v1",
            "IDeckFirstRunSetupView",
            "installMadeiraDock()",
            "Wine Mono",
            "requestStikDebugJIT()",
            "requestBuiltInJIT()",
        ):
            self.assertIn(phrase, swift)
        environment = (ROOT / "iDeck/WindowsInstallerEnvironment.swift").read_text()
        self.assertIn("VisualCRuntimeBootstrap.download", environment)
        self.assertIn("VisualCRuntimeBootstrap.extractAndInstall", environment)

    def test_madeira_cmd_and_mono_are_required_in_native_ipa(self):
        stage = repo_text("scripts/stage_madeira_payload.sh")
        build = repo_text("scripts/build_madeira_components.sh")
        verify = repo_text("scripts/verify_madeira_bundle.py")
        kit = repo_text("scripts/madeira_native_kit.py")
        workflow = repo_text(".github/workflows/ios.yml")
        coordinator = repo_text("iDeck/SystemCoordinator.swift")

        self.assertIn("programs/cmd/arm64ec-windows/cmd.exe", build)
        for source in (stage, verify, kit):
            self.assertIn("arm64ec-windows/cmd.exe", source)
        self.assertIn("bundle_wine_mono:", workflow)
        self.assertIn("default: true", workflow.split("bundle_wine_mono:", 1)[1].split("export_runtime_kit:", 1)[0])
        self.assertIn("dockInstallAfterPrefix", coordinator)
        self.assertIn("steamComponentsProgress = ", coordinator)

    def test_store_icons_and_launcher_executables(self):
        settings = repo_text("iDeck/SettingsView.swift")
        models = repo_text("iDeck/WindowsLibraryModels.swift")
        self.assertIn("StoreBadgeEA", settings)
        # EA games need no EA app (Madeira's EA support).
        self.assertNotIn("EAappInstaller.exe", settings + models)
        self.assertIn("EASignInView()", settings)

    def test_memory_plus_is_entitlement_not_runtime_switch(self):
        entitlements = repo_text("iDeck/iDeck.entitlements")
        settings = repo_text("iDeck/SettingsView.swift")
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", entitlements)
        self.assertIn("Memory+", settings)


if __name__ == "__main__":
    unittest.main()
