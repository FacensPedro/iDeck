import importlib.util
import pathlib
import plistlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ideck_runtime_profile", ROOT / "scripts/stamp_ideck_runtime_profile.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class RuntimeProfileStampTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = pathlib.Path(self.temp.name)

    def native_manifest(self, graphics="d3d11", wow64=False):
        data = {
            "runtimeABI": 1,
            "fexInProcess": True, "wineInProcess": True, "dxmtLinked": True,
            "graphicsBackend": graphics, "d3d12Linked": graphics == "d3d12",
            "wow64Enabled": wow64,
        }
        (self.app / "MadeiraRuntimeManifest.plist").write_bytes(plistlib.dumps(data))
        if graphics == "d3d12":
            converter = self.app / "d3d12/libmetalirconverter.dylib"
            converter.parent.mkdir(parents=True, exist_ok=True)
            converter.write_bytes(b"test-only-fixture")
        if wow64:
            x86 = self.app / "i386-windows/ntdll.dll"
            x86.parent.mkdir(parents=True, exist_ok=True)
            x86.write_bytes(b"MZtest-only-fixture")

    def test_interface_only_stamped_without_native_success_claim(self):
        profile = module.stamp(self.app)
        self.assertEqual(profile["runtimeKind"], "interface-only")
        self.assertEqual(profile["graphicsBackend"], "none")
        self.assertFalse(any(profile[field] for field in (
            "wow64Enabled", "wineMonoBundled", "metalShaderConverterBundled"
        )))
        self.assertEqual(plistlib.loads((self.app / "iDeckRuntimeProfile.plist").read_bytes()), profile)

    def test_native_request_rejects_interface_only(self):
        with self.assertRaisesRegex(ValueError, "Native runtime requested"):
            module.stamp(self.app, require_native=True, expected_graphics="d3d11")
        self.assertFalse((self.app / "iDeckRuntimeProfile.plist").exists())

    def test_native_d3d11_wow64_and_mono_detected_from_actual_files(self):
        self.native_manifest("d3d11", wow64=True)
        mono = self.app / "wine-mono/bin/libmono-2.0-x86.dll"
        mono.parent.mkdir(parents=True, exist_ok=True)
        mono.write_bytes(b"MZtest-only-fixture")
        profile = module.stamp(self.app, require_native=True, expected_graphics="d3d11")
        self.assertEqual(profile["runtimeKind"], "madeira-native")
        self.assertEqual(profile["graphicsBackend"], "d3d11")
        self.assertTrue(profile["wow64Enabled"])
        self.assertTrue(profile["wineMonoBundled"])
        self.assertFalse(profile["metalShaderConverterBundled"])

    def test_native_d3d12_requires_converter_asset(self):
        self.native_manifest("d3d12")
        (self.app / "d3d12/libmetalirconverter.dylib").unlink()
        with self.assertRaisesRegex(ValueError, "converter presence"):
            module.stamp(self.app, require_native=True, expected_graphics="d3d12")

    def test_invalid_manifest_is_rejected_not_treated_as_interface(self):
        self.native_manifest("d3d11")
        (self.app / "MadeiraRuntimeManifest.plist").write_bytes(plistlib.dumps({"wineInProcess": True}))
        with self.assertRaisesRegex(ValueError, "Invalid native runtime manifest"):
            module.stamp(self.app)

    def test_ui_rejects_interface_only_before_jit_or_steam_import(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        for method in ("func launchSteam()", "func launchWindowsExecutable(", "func launchSteamGame("):
            self.assertIn(method, coordinator)
        self.assertEqual(coordinator.count("guard MadeiraBundleIdentity.isNative else {"), 3)
        self.assertEqual(coordinator.count("setWindowsStatus(MadeiraBundleIdentity.missingRuntimeMessage)"), 3)
        app = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn("static var nativeManifest: [String: Any]?", app)
        self.assertIn("static var isNative: Bool", app)
        settings = (ROOT / "iDeck/SettingsView.swift").read_text()
        for field in ("runtimeKind", "graphicsBackend", "wow64Enabled",
                      "wineMonoBundled", "metalShaderConverterBundled"):
            self.assertIn(field if field != "runtimeKind" else "MadeiraBundleIdentity.isNative", settings)

    def test_builder_preserves_strict_missing_runtime_error(self):
        builder = (ROOT / "scripts/build_ipa.sh").read_text()
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        self.assertIn("scripts/stamp_ideck_runtime_profile.py --app", builder)
        self.assertIn("python3 scripts/verify_madeira_bundle.py --app \"$APP\" --require", builder)
        self.assertIn('raise SystemExit("Native runtime requested but the packaged IPA is interface-only")', workflow)


if __name__ == "__main__":
    unittest.main()
