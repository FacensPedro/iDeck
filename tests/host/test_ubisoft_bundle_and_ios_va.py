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
        self.assertIn("URLSession.shared.download(from: client.downloadURL)", coordinator)

    def test_ubisoft_install_detection(self):
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn('"Program Files/Ubisoft/Ubisoft Game Launcher"', coordinator)
        self.assertIn('name: "InstallDir"', coordinator)

    def test_store_setup_installs_launchers_in_initial_setup(self):
        view = text("iDeck/MainView.swift")
        step = view[view.index("private var launchersStep: some View"):view.index("// MARK: - JIT")]
        self.assertIn("coordinator.installDefaultStoreClients()", step)
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn('case .ea: return "/quiet /norestart"', coordinator)
        self.assertIn('case .ubisoft: return "/S"', coordinator)
        self.assertIn('MadeiraRuntime.file("i386-windows/cmd.exe")', coordinator)
        self.assertIn(r'C:\windows\sysnative\services.exe', coordinator)
        self.assertNotIn("stageNativeShell", coordinator)

    def test_launchers_install_without_wine_screen(self):
        view = text("iDeck/MainView.swift")
        self.assertIn("!coordinator.storeSetupInBackground && (coordinator.windowsStatus", view)
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn("self.storeSetupInBackground = true", coordinator)
        self.assertIn("self.storeClientError = status == \"Windows Ready\" ? nil : status", coordinator)
        settings = text("iDeck/SettingsView.swift")
        self.assertIn("NavigationLink { ubisoftPage }", settings)
        self.assertIn("StoreClientButton(client: .ea", settings)

    def test_background_launcher_install_has_hidden_metal_surface(self):
        view = text("iDeck/MainView.swift")
        self.assertIn("WindowsRendererView(hiddenSurface: true)", view)
        self.assertEqual(view.count(".background(BackgroundStoreSetupSurface(coordinator: coordinator))"), 2)
        renderer = text("iDeck/WindowsRendererView.swift")
        self.assertIn("host.isHidden = viewport.hiddenSurface", renderer)
        self.assertIn("_ = show(viewport.hiddenSurface ? 1 : 0)", renderer)
        self.assertIn("attachViewport(next)", renderer)

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
