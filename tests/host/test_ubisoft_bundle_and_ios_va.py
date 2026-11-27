import split_sources  # noqa: F401  (iDeck 3.0 split files)
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def text(path):
    return (ROOT / path).read_text()


class UbisoftConnectBundleTests(unittest.TestCase):
    def test_installers_are_not_in_the_ipa(self):
        build = text("scripts/build_ipa.sh")
        self.assertNotIn("bundle_ubisoft_connect.sh", build)
        self.assertNotIn("EAappInstaller.exe", build)
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn("try await download(client.downloadURL, to: folder.appendingPathComponent(client.installerName))", coordinator)

    def test_ubisoft_install_detection(self):
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn('"Program Files/Ubisoft/Ubisoft Game Launcher"', coordinator)
        self.assertIn('name: "InstallDir"', coordinator)

    def test_store_setup_installs_launchers_in_initial_setup(self):
        view = text("iDeck/MainView.swift")
        step = view[view.index("var launchersStep: some View"):view.index("// MARK: - JIT")]
        self.assertIn("coordinator.installDefaultStoreClients()", step)
        coordinator = text("iDeck/SystemCoordinator.swift")
        # No Windows program runs: no silent switches, no cmd.exe, no services.exe.
        self.assertNotIn('MadeiraRuntime.file("i386-windows/cmd.exe")', coordinator)
        self.assertNotIn("silentSwitches", coordinator)

    def test_launchers_install_without_wine(self):
        view = text("iDeck/MainView.swift")
        self.assertNotIn("!coordinator.storeSetupInBackground && (coordinator.windowsStatus", view)
        self.assertNotIn("BackgroundStoreSetupSurface", view)
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn("storeSetupInBackground = true", coordinator)
        settings = text("iDeck/SettingsView.swift")
        self.assertIn("NavigationLink { ubisoftPage }", settings)
        self.assertIn("StoreClientButton(client: .ea", settings)

    def test_dock_installs_bundled_launcher_silently(self):
        src = text("iDeck/Vendor/Madeira/DockInstallers.swift")
        self.assertIn("enum UbisoftConnectBundle", src)
        self.assertIn('arguments: "/S"', src)
        self.assertIn("UbisoftConnectBundle.installed(drive: drive)", src)
        self.assertIn("pending.insert(process, at: 0)", src)


class IosVaFloorAndPage0Tests(unittest.TestCase):
    def test_patch_is_in_series(self):
        self.assertIn("native    .      madeira-ios-va-floor-page0-skip.patch", text("patches/series.txt"))

    def test_patch_contents(self):
        patch = text("patches/madeira-ios-va-floor-page0-skip.patch")
        self.assertIn("MADEIRA_PAGE0_PROBE", patch)
        self.assertIn("refused low band ends at", patch)


class FexConfigFilesTests(unittest.TestCase):
    def test_bridge_writes_empty_fex_config(self):
        bridge = text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
        self.assertIn('@"drive_c/ProgramData/fex-emu"', bridge)
        self.assertIn('@"Config.json"', bridge)
        self.assertIn('@"AppConfig"', bridge)


if __name__ == "__main__":
    unittest.main()
