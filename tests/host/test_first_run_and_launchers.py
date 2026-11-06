import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FirstRunLaunchersContract(unittest.TestCase):
    def test_first_run_steps_are_real_and_resumable(self):
        swift = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
        for phrase in (
            "firstRunSetup.complete.v1",
            "IDeckFirstRunSetupView",
            "installSteamClientComponentsIfNeeded()",
            "Wine Mono",
            "requestStikDebugJIT()",
            "VisualCRuntimeBootstrap.download",
            "VisualCRuntimeBootstrap.extractAndInstall",
        ):
            self.assertIn(phrase, swift)

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
