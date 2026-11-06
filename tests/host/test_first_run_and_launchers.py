import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FirstRunLaunchersContract(unittest.TestCase):
    def test_first_run_steps_are_real_and_resumable(self):
        swift = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
        for phrase in (
            "firstRunSetup.complete.v1",
            "IDeckFirstRunSetupView",
            "installMadeiraDock()",
            "Wine Mono",
            "requestStikDebugJIT()",
            "requestBuiltInJIT()",
            "VisualCRuntimeBootstrap.download",
            "VisualCRuntimeBootstrap.extractAndInstall",
        ):
            self.assertIn(phrase, swift)

    def test_madeira_cmd_and_mono_are_required_in_native_ipa(self):
        stage = (ROOT / "scripts/stage_madeira_payload.sh").read_text(encoding="utf-8")
        build = (ROOT / "scripts/build_madeira_components.sh").read_text(encoding="utf-8")
        verify = (ROOT / "scripts/verify_madeira_bundle.py").read_text(encoding="utf-8")
        kit = (ROOT / "scripts/madeira_native_kit.py").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")

        self.assertIn("programs/cmd/arm64ec-windows/cmd.exe", build)
        for source in (stage, verify, kit):
            self.assertIn("arm64ec-windows/cmd.exe", source)
        self.assertIn("bundle_wine_mono:", workflow)
        self.assertIn("default: true", workflow.split("bundle_wine_mono:", 1)[1].split("export_runtime_kit:", 1)[0])
        self.assertIn("dockInstallAfterPrefix", coordinator)
        self.assertIn("steamComponentsProgress = ", coordinator)

    def test_store_icons_and_launcher_executables(self):
        settings = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
        models = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text(encoding="utf-8")
        for name in ("StoreBadgeEA", "StoreBadgeUbisoft"):
            self.assertIn(name, settings)
        for name in ("EAappInstaller.exe", "UbisoftConnectInstaller.exe"):
            self.assertIn(name, settings)
            self.assertIn(name, models)

    def test_usb_launcher_paths_are_narrowly_scoped(self):
        swift = (ROOT / "iDeck/IRelayDeviceService.swift").read_text(encoding="utf-8")
        self.assertIn('"protocol": 4', swift)
        for folder in ('WindowsDownloads/Launchers/EA', 'WindowsDownloads/Launchers/Ubisoft'):
            self.assertIn(folder, swift)

    def test_memory_plus_is_entitlement_not_runtime_switch(self):
        entitlements = (ROOT / "iDeck/iDeck.entitlements").read_text(encoding="utf-8")
        settings = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
        self.assertIn("com.apple.developer.kernel.increased-memory-limit", entitlements)
        self.assertIn("Memory+", settings)


if __name__ == "__main__":
    unittest.main()
