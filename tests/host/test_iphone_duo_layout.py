import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class IPhoneDuoAdaptiveLayoutTests(unittest.TestCase):
    def test_metal_uses_attached_window_not_global_screen(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        self.assertNotIn("contentScaleFactor = UIScreen.main.scale", renderer)
        self.assertIn("let sceneScale = window.screen.scale", renderer)
        self.assertIn("host.contentScaleFactor = sceneScale", renderer)
        self.assertIn("layoutViewport(viewport)", renderer)
        self.assertIn("let frame = viewport.convert(viewport.bounds, to: window)", renderer)
        self.assertIn("if host.frame != positioned", renderer)

    def test_native_drawable_size_is_seeded_only_before_madeira_takes_ownership(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        self.assertIn("if !layerRegistered {", renderer)
        self.assertIn("host.metalLayer.drawableSize = CGSize(", renderer)
        self.assertIn("(host.bounds.width * scale).rounded()", renderer)
        self.assertIn("Do NOT write host.metalLayer.drawableSize here", renderer)
        self.assertIn("layerRegistered = true", renderer)
        self.assertNotIn("CGRect(x: 0, y: 0, width: 800, height: 600)", renderer)

    def test_controls_follow_compact_and_regular_width(self):
        session = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertIn("@Environment(\\.horizontalSizeClass) private var horizontalSizeClass", session)
        self.assertIn("if horizontalSizeClass != .compact {", session)
        self.assertIn('Text("FPS:', session)
        self.assertIn("coordinator.requestCloseWindowsSession", session)
        self.assertIn("WineInputBridge.shared.startBridging()", session)

    def test_xcode_still_targets_iphone_and_ipad_without_forcing_a_device_model(self):
        project = (ROOT / "iDeck.xcodeproj/project.pbxproj").read_text()
        self.assertIn('TARGETED_DEVICE_FAMILY = "1,2";', project)
        self.assertIn("INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone", project)
        self.assertIn("UIInterfaceOrientationLandscapeLeft", project)

    def test_opt_in_full_screen_requires_modern_iphone_duo_sdk(self):
        builder = (ROOT / "scripts/build_ipa.sh").read_text()
        self.assertIn('IDECK_REQUIRE_IPHONE_DUO_SDK:-0', builder)
        self.assertIn("SDK_MAJOR == 27 && SDK_MINOR < 1", builder)
        self.assertIn("iPhone Duo full-display layout requires Xcode", builder)

    def test_device_acceptance_supports_new_and_old_ios_build_keys(self):
        source = (ROOT / "scripts/verify_madeira_device_acceptance.py").read_text()
        self.assertIn('"os_build": ""', source)
        self.assertIn('device.get("os_build") or device.get("ipad_os_build")', source)
        self.assertIn("device_compatibility_proven_automatically", source)


if __name__ == "__main__":
    unittest.main()
