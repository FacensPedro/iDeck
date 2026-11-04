import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MadeiraTouchVirtualControllerTests(unittest.TestCase):
    def test_uses_existing_madeira_pad_transport_and_free_slot(self):
        native = (ROOT / "iDeck/NativeRuntime/DirectInputBridge.mm").read_text()
        self.assertIn('"winios_gamepad_set_state"', native)
        self.assertIn('"winios_hidpad_set_state"', native)
        self.assertIn("int virtualSlot = -1", native)
        self.assertIn("if (!g_slots[i]) { virtualSlot = i; break; }", native)
        self.assertIn("if (i == virtualSlot)", native)
        self.assertIn("publish_pad(i, &state)", native)
        self.assertIn("publish_hid(&hid)", native)
        self.assertIn("(hasController || g_touchEnabled)", native)
        self.assertIn("static IDeckGamepad g_touchState = {}", native)

    def test_touch_controls_are_removed(self):
        session = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertNotIn("IDeckTouchGamepadOverlay", session)
        self.assertNotIn("ideck_touch_gamepad_set_state(", session)
        settings = (ROOT / "iDeck/SettingsView.swift").read_text()
        self.assertNotIn('tr("Show touch controls")', settings)
        view = (ROOT / "iDeck/MainView.swift").read_text()
        self.assertNotIn("$profile.touchControlPreset", view)
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertNotIn("IDECK_TOUCH_CONTROLS_ACTIVE", env)

    def test_session_release_clears_virtual_and_hardware_slots(self):
        native = (ROOT / "iDeck/NativeRuntime/DirectInputBridge.mm").read_text()
        release = native.split("static void stop_native_gamepads(void)", 1)[1].split(
            'extern "C" void ideck_gamepad_end_session', 1
        )[0]
        for token in ("g_sessionActive = NO", "publish_pad(i, NULL)",
                      "zero_vibration(i)", "publish_hid(NULL)",
                      "g_touchState = {}", "g_touchEnabled = NO"):
            self.assertIn(token, release)
        self.assertIn("g_touchEnabled && g_appActive", native)

    def test_metal_does_not_steal_on_screen_controller_touches(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        # No on-screen controller band: the surface fills all below the toolbar.
        self.assertNotIn("IDECK_TOUCH_CONTROLS_ACTIVE", renderer)
        self.assertIn("frame.height - toolbar", renderer)
        self.assertNotIn("isUserInteractionEnabled = true", renderer)


if __name__ == "__main__":
    unittest.main()
