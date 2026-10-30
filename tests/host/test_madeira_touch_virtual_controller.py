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

    def test_touch_preset_is_persisted_and_distinct_from_native_controller_mode(self):
        profile = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
        self.assertIn('var touchControlPreset: String = "xbox"', profile)
        self.assertIn("decodeIfPresent(String.self, forKey: .touchControlPreset)", profile)
        self.assertIn('["xbox", "minimal", "off"]', profile)
        self.assertIn("controllerAPI", profile)
        view = (ROOT / "iDeck/MainView.swift").read_text()
        self.assertIn('selection: $profile.touchControlPreset', view)
        self.assertIn('choices: ["xbox", "minimal", "off"]', view)
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn('setenv("IDECK_TOUCH_CONTROLS_ACTIVE"', env)

    def test_analog_and_buttons_are_sent_into_native_slot_on_touch(self):
        session = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertIn("IDeckTouchGamepadOverlay(preset: preset)", session)
        self.assertIn("DragGesture(minimumDistance: 0)", session)
        self.assertIn("ideck_touch_gamepad_set_state(", session)
        self.assertIn("ideck_touch_gamepad_set_enabled(1)", session)
        self.assertIn("ideck_touch_gamepad_set_enabled(0)", session)
        self.assertIn("pad.buttons |= bit", session)
        self.assertIn("pad.buttons &= ~bit", session)
        header = (ROOT / "iDeck/NativeRuntime/RuntimeSupport.h").read_text()
        self.assertIn("void ideck_touch_gamepad_set_state(", header)
        self.assertIn("void ideck_touch_gamepad_set_enabled(", header)

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
        self.assertIn("IDECK_TOUCH_CONTROLS_ACTIVE", renderer)
        self.assertIn("controlsHeight", renderer)
        self.assertIn("frame.height - toolbar - controlsHeight", renderer)
        self.assertNotIn("isUserInteractionEnabled = true", renderer)


if __name__ == "__main__":
    unittest.main()
