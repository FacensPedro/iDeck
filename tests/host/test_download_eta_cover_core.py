import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(name):
    return (ROOT / name).read_text(encoding="utf-8")


class DownloadETACoreContract(unittest.TestCase):
    def test_eta_uses_real_speed_not_guess(self):
        eta = source("iDeck/DownloadSpeed.swift")
        self.assertIn("total - done", eta)
        self.assertIn("bytesPerSecond.isFinite", eta)
        self.assertIn("bytesPerSecond > 1_024", eta)
        view = source("iDeck/MainView.swift")
        self.assertIn("downloadETASeconds[game.id]", view)
        self.assertIn('let remaining = DownloadETA.label(eta)', view)
        self.assertIn('Label(tr("Time left") + ": " + remaining', view)

    def test_download_button_over_blurred_cover_is_separate_control(self):
        view = source("iDeck/MainView.swift")
        self.assertIn("Image(\"DownloadCloud\")", view)
        self.assertIn("downloadCoverButton", view)
        self.assertIn(".blur(radius:", view)
        self.assertTrue((ROOT / "iDeck/Assets.xcassets/DownloadCloud.imageset/download.png").exists())

    def test_first_architecture_bootstrap_is_win64_wow64(self):
        view = source("iDeck/MainView.swift")
        self.assertIn('private func installWindowsRuntime()', view)
        self.assertIn('hasWoW64Runtime()', view)
        self.assertIn('coordinator.installMadeiraDock()', view)
        self.assertIn('case windows, dock, jit, summary', view)
        self.assertIn('coordinator.openMadeiraWorkspace()', view)
        # Steam's client and DLLs are installed only by the Madeira Dock step.
        self.assertNotIn('SteamVideoLibraries.fetch', view)
        self.assertNotIn('statusRow("Steam client", steamClientReady)', view)
        # Visual C++ and Wine Mono are installed on demand, not by the setup.
        for component in ('VisualCRuntimeLegacy.installAll', 'wineMono.install()'):
            self.assertNotIn(component, view)
        windows = source("iDeck/WindowsEnvironment.swift")
        self.assertIn('setenv("WINEARCH", "win64", 1)', windows)

    def test_jit_defaults_to_624_and_hot_path_avoids_lock(self):
        settings = source("iDeck/SettingsView.swift")
        self.assertIn('private var wineJITPoolMiB = 560', settings)
        coordinator = source("iDeck/SystemCoordinator.swift")
        self.assertIn('as? Int ?? 560', coordinator)
        core = source("iDeck/NativeRuntime/FEXRuntime.cpp")
        self.assertIn('std::atomic<bool> fex_initialized', core)
        self.assertIn('std::memory_order_acquire', core)

    def test_madeira_game_config_is_cached_and_invalidated(self):
        config = source("iDeck/MadeiraConfig.swift")
        self.assertIn('private static let gameCache', config)
        self.assertIn('invalidateGameCache()', config)
        self.assertIn('info.st_ino', config)


if __name__ == "__main__":
    unittest.main()
