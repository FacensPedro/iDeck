import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
RENDERER = (ROOT / "iDeck/WindowsRendererView.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
SERVER = (ROOT / "iDeck/NativeRuntime/WineServerBridge.m").read_text(encoding="utf-8")
PREFIX = (ROOT / "iDeck/PrefixInstaller.swift").read_text(encoding="utf-8")
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text(encoding="utf-8")
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
GRAPHICS = (ROOT / "iDeck/GraphicsConfig.swift").read_text(encoding="utf-8")


class WineBlackScreenAndFastStartupTests(unittest.TestCase):
    def test_surface_is_window_hosted_and_persists_across_view_teardown(self):
        self.assertIn("final class MadeiraWindowMetalHost: UIView", RENDERER)
        self.assertIn("static let shared = MadeiraWindowMetalHost(", RENDERER)
        self.assertIn("override class var layerClass: AnyClass { return CAMetalLayer.self }", RENDERER)
        self.assertIn("window.addSubview(host)", RENDERER)
        self.assertIn("host.removeFromSuperview()", RENDERER)
        self.assertIn("MadeiraWindowMetalHost.shared.removeFromSuperview()", RENDERER)
        self.assertNotIn("MTKView(", RENDERER)
        self.assertNotIn("MTKView: UIViewRepresentable", RENDERER)
        self.assertIn("host.metalLayer.device != nil", RENDERER)
        self.assertIn("host.bounds.width >= 2", RENDERER)
        self.assertIn("if !layerRegistered,", RENDERER)
        self.assertNotIn("setter(nil)", RENDERER)
        self.assertIn("view.isUserInteractionEnabled = false", RENDERER)
        self.assertIn("isUserInteractionEnabled = false", RENDERER)

    def test_renderer_does_not_fight_guest_drawable_size(self):
        self.assertIn("metalLayer.drawableSize = CGSize(width: 800, height: 600)", RENDERER)
        self.assertEqual(RENDERER.count("metalLayer.drawableSize ="), 1)
        self.assertIn("lastGuestSize = nil", RENDERER)
        self.assertIn("winios_display_mode_changed", RENDERER)
        self.assertIn("let toolbar = min(84.0, max(64.0", RENDERER)
        self.assertIn("host.frame = positioned", RENDERER)
        self.assertIn('"winios_set_compositor_frame"', RENDERER)
        self.assertIn('"winios_set_desktop_rect"', RENDERER)
        self.assertIn('"winios_compositor_set_hidden"', RENDERER)

    def test_missing_native_renderer_fails_fast_instead_of_waiting_on_black_screen(self):
        self.assertIn("guard WindowsRendererView.isNativeDisplayLinked else {", COORDINATOR)
        self.assertIn("this IPA has no linked Madeira Metal display backend", COORDINATOR)
        self.assertIn("remainingChecks: Int = 80", COORDINATOR)
        self.assertIn("deadline: .now() + 0.05", COORDINATOR)
        self.assertIn("WindowsRendererView.isReadyForFrames", COORDINATOR)

    def test_wine_startup_paths_keep_safety_and_improve_response(self):
        self.assertIn("for (unsigned int attempt = 0; attempt < 50; ++attempt)", SERVER)
        self.assertIn("usleep(5000)", SERVER)
        self.assertIn("for (unsigned int attempt = 0; attempt < 190; ++attempt)", SERVER)
        self.assertIn("usleep(25000)", SERVER)
        self.assertIn("DispatchQueue.global(qos: .userInitiated).async { [weak self] in", PREFIX)
        self.assertIn("steamRegistryInitializedPrefixes = Set<String>()", ENVIRONMENT)
        self.assertIn("steamRegistryInitializedPrefixes.insert(prefix)", ENVIRONMENT)
        self.assertIn("if FileManager.default.fileExists(atPath: prefix + \"/user.reg\")", ENVIRONMENT)

    def test_dxvk_hud_remains_automatic_without_user_settings_toggle(self):
        self.assertIn('setenv("DXVK_HUD", "devinfo,fps", 0)', GRAPHICS)
        self.assertNotIn('toggleRow(title: tr("Metal diagnostics HUD")', SETTINGS)
        self.assertNotIn('toggleRow(title: tr("DXVK HUD")', SETTINGS)
        self.assertIn('toggleRow(title: tr("Show FPS, CPU & GPU overlay")', SETTINGS)


if __name__ == "__main__":
    unittest.main()
