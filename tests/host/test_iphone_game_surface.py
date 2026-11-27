import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class IPhoneGameSurfaceTests(unittest.TestCase):
    def test_first_frame_counts_gl_and_window_images(self):
        src = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertIn('NativeSymbol.address("madeira_frame_count")', src)
        self.assertIn('NativeSymbol.address("winios_surface_present_count")', src)

    def test_iphone_uses_full_height_after_first_frame(self):
        view = (ROOT / "iDeck/NativeRuntime/WindowsRendererView.swift").read_text()
        self.assertIn("let bounds = frame", view)
        session = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertIn("SessionWindowOverlay(interactive: true,", session)
        self.assertIn(".statusBarHidden(true)", session)


if __name__ == "__main__":
    unittest.main()
