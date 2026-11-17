import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def text(path):
    return (ROOT / path).read_text()


class UbisoftConnectBundleTests(unittest.TestCase):
    def test_installer_ships_in_the_app(self):
        build = text("scripts/build_ipa.sh")
        self.assertIn('bash scripts/bundle_ubisoft_connect.sh "$APP"', build)
        script = text("scripts/bundle_ubisoft_connect.sh")
        self.assertIn('OUT="$APP/ubisoft/UbisoftConnectInstaller.exe"', script)
        self.assertIn('"MZ"', script)

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
