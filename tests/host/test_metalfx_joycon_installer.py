import split_sources  # noqa: F401  (iDeck 3.0 split files)
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

    def test_refused_foreground_keeps_the_press(self):
        self.assertIn("native    .      madeira-installer-click-delivery.patch", text("patches/series.txt"))
        msg = text("patches/madeira-installer-click-delivery.patch")
        self.assertIn('ios_click_trace( msg, hittest, "foreground refused, press kept" );', msg)
        self.assertIn('"[click] msg=0x%x hwnd=%p class=%s hit=%d at (%d,%d): %s\\n"', msg)


class SteamPlayingSessionTests(unittest.TestCase):
    def test_other_playing_session_is_ended_before_the_dock(self):
        proto = text("iDeck/SwiftSteam/Core/SteamProtocol.swift")
        self.assertIn("case clientPlayingSessionState = 9600", proto)
        self.assertIn("case clientKickPlayingSession = 9601", proto)
        session = text("iDeck/SwiftSteam/Core/SteamSession.swift")
        self.assertIn("func freeOtherPlayingSession(timeout: TimeInterval = 10) async -> Bool", session)
        self.assertIn("handlePlayingSessionState(message.body)", session)
        manager = text("iDeck/SteamManager.swift")
        self.assertLess(manager.index("await session.freeOtherPlayingSession()"),
                        manager.index("await session.suspend()"))


if __name__ == "__main__":
    unittest.main()
