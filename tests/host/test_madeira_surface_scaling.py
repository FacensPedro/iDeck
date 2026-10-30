import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MadeiraSurfaceScalingTests(unittest.TestCase):
    def test_profile_persists_four_modes_and_defaults_to_fit(self):
        source = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
        self.assertIn('var surfaceScaling: String = "fit"', source)
        self.assertIn("case id, title, arguments, resolution, surfaceScaling", source)
        self.assertIn("decodeIfPresent(String.self, forKey: .surfaceScaling)", source)
        self.assertIn('["fit", "fill", "stretch", "aspect"]', source)
        view = (ROOT / "iDeck/MainView.swift").read_text()
        self.assertIn('selection: $profile.surfaceScaling', view)
        self.assertIn('choices: ["fit", "fill", "stretch", "aspect"]', view)
        self.assertIn("profile.controllerAPI", source)

    def test_guest_virtual_mode_read_dynamically_from_madeira(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        self.assertIn('"winios_screen_size"', renderer)
        self.assertIn("read(&width, &height)", renderer)
        self.assertIn("currentGuestSize", renderer)
        self.assertIn('IDECK_DISPLAY_SCALING', renderer)
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn('setenv("IDECK_DISPLAY_SCALING"', env)
        self.assertIn("profile.surfaceScaling", env)

    def test_native_metal_drawable_is_only_seeded_before_registration(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        self.assertIn("if !layerRegistered {", renderer)
        self.assertIn("host.metalLayer.drawableSize = CGSize(", renderer)
        self.assertIn("Do NOT write host.metalLayer.drawableSize here", renderer)
        self.assertIn("drawableObservation = host.metalLayer.observe", renderer)
        self.assertIn("DispatchQueue.main.async { refreshNativeDisplay() }", renderer)

    def test_metal_compositor_and_touch_share_exact_rect(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        geometry = (ROOT / "iDeck/RuntimeConfiguration.swift").read_text()
        self.assertIn("RuntimeConfiguration.surfaceRect(", renderer)
        self.assertIn("RuntimeConfiguration.guestPoint(point, guest: surface.guest", renderer)
        self.assertIn("currentSurface = (guest: guest, drawable: drawable, bounds: bounds, mode: mode)", renderer)
        self.assertIn("setDesktop(Double(positioned.minX - frame.minX)", renderer)
        self.assertIn('"winios_set_compositor_frame"', renderer)
        self.assertIn("case fit, fill, stretch, aspect", geometry)
        self.assertIn("let useDrawable = mode == .aspect", geometry)
        self.assertIn("let scale = mode == .fill ? max(sx, sy) : min(sx, sy)", geometry)
        session = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertNotIn("let fitted = RuntimeConfiguration.fittedSize(", session)
        self.assertIn(".frame(width: geometry.size.width, height: geometry.size.height)", session)


if __name__ == "__main__":
    unittest.main()
