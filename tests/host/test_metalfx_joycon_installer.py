import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def text(path):
    return (ROOT / path).read_text()


class MetalFXModesTests(unittest.TestCase):
    def test_one_metalfx_setting_with_modes(self):
        model = text("iDeck/WindowsLibraryModels.swift")
        self.assertIn('"Quality + frame generation"', model)
        self.assertIn("static let metalFXAllowed = ProcessInfo.processInfo.physicalMemory > 7 << 30", model)
        view = text("iDeck/MainView.swift")
        self.assertIn('DetailPickerRow(title: "MetalFX"', view)
        self.assertNotIn('tr("Frame generation"), isOn', view)
        self.assertIn('Picker("MetalFX"', text("iDeck/SessionControlsSheet.swift"))

    def test_metalfx_off_below_8gb(self):
        env = text("iDeck/WindowsEnvironment.swift")
        self.assertIn("let metalFXOn = profile.metalFXEnabled && WindowsGameProfile.metalFXAllowed", env)
        self.assertIn("profile.frameGeneration && WindowsGameProfile.metalFXAllowed", env)


class JoyConTests(unittest.TestCase):
    def test_single_joycon_is_a_pad(self):
        bridge = text("iDeck/NativeRuntime/DirectInputBridge.mm")
        self.assertIn("static IDeckGamepad state_for_micro(GCController *controller)", bridge)
        self.assertIn("if (!ideck_pad_usable(controller)) continue;", bridge)
        self.assertIn("case .joyCon", text("iDeck/InputManager.swift"))


class InstallerClickTests(unittest.TestCase):
    def test_click_moves_then_presses(self):
        touch = text("iDeck/TouchMouseView.swift")
        self.assertIn("> 12 { moved = true }", touch)
        self.assertIn("self.downSent = true", touch)


if __name__ == "__main__":
    unittest.main()
