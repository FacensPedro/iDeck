import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
INPUT = (ROOT / "iDeck/WineInputBridge.swift").read_text()
PAD = (ROOT / "iDeck/NativeRuntime/DirectInputBridge.mm").read_text()
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()


class WineGamepadViewLifecycleTests(unittest.TestCase):
    def test_swiftui_view_disappearance_never_unplugs_a_live_guest_pad(self):
        stop = INPUT.split("func stopBridging()", 1)[1].split("\n    }", 1)[0]
        guard = stop.split("ideck_controller_stop()", 1)[0]
        for check in ("!ideck_wineprocess_running()",
                      "!ideck_wineserver_running()",
                      "ideck_wineprocess_thread_finished()"):
            self.assertIn(check, guard)
        self.assertIn("WineInputBridge.shared.stopBridging()", SESSION)

    def test_stop_wireless_discovery_does_not_disconnect_live_wine_devices(self):
        stop = INPUT.split("func stopBridging()", 1)[1].split("\\n    }", 1)[0]
        self.assertIn("ideck_controller_stop_discovery()", stop)
        self.assertLess(stop.index("ideck_controller_stop_discovery()"),
                        stop.index("guard !ideck_wineprocess_running()"))
        api = (ROOT / "iDeck/NativeRuntime/RuntimeSupport.h").read_text()
        self.assertIn("void ideck_controller_stop_discovery(void);", api)
        method = PAD.split('extern "C" void ideck_controller_stop_discovery(void)', 1)[1].split(
            'extern "C" void ideck_controller_stop(void)', 1
        )[0]
        self.assertIn("[GCController stopWirelessControllerDiscovery]", method)
        self.assertNotIn("ideck_gamepad_end_session()", method)
        self.assertIn("ideck_gamepad_end_session()", PAD.split(
            'extern "C" void ideck_controller_stop(void)', 1
        )[1])

    def test_native_session_still_cleans_up_gamepads_after_wine_and_server_exit(self):
        cleanup = NATIVE.split('extern "C" bool ideck_runtime_complete_session(void)', 1)[1]
        self.assertIn("ideck_wineprocess_running()", cleanup)
        self.assertIn("ideck_wineserver_running()", cleanup)
        self.assertIn("!ideck_wineprocess_thread_finished()", cleanup)
        self.assertIn("ideck_gamepad_end_session()", cleanup)
        self.assertLess(cleanup.index("ideck_wineserver_running()"), cleanup.index("ideck_gamepad_end_session()"))

    def test_background_clears_stuck_virtual_buttons_before_sampling(self):
        start = PAD.index("g_backgroundObserver = [center addObserverForName:UIApplicationWillResignActiveNotification")
        end = PAD.index("g_foregroundObserver =", start)
        code = PAD[start:end]
        for name in ("g_appActive = NO", "g_touchState = {}",
                     "output_active(NO)", "sample_gamepads()", "update_sample_timer()"):
            self.assertIn(name, code)
        self.assertLess(code.index("g_touchState = {}"), code.index("sample_gamepads()"))
        self.assertIn("g_appActive = YES; output_active(YES); refresh_controllers();", PAD)

    def test_virtual_gamepad_disappearance_and_full_shutdown_both_release_buttons(self):
        self.assertIn("ideck_touch_gamepad_set_enabled(0)", SESSION)
        disable = PAD.split('extern "C" void ideck_touch_gamepad_set_enabled(int enabled)', 1)[1].split(
            'extern "C" void ideck_touch_gamepad_set_state', 1
        )[0]
        self.assertIn("if (!g_touchEnabled) g_touchState = {}", disable)
        self.assertIn("if (g_sessionActive)", disable)
        stop = PAD.split("static void stop_native_gamepads(void)", 1)[1].split(
            'extern "C" void ideck_gamepad_end_session', 1
        )[0]
        self.assertIn("g_touchState = {}", stop)
        self.assertIn("g_touchEnabled = NO", stop)


if __name__ == "__main__":
    unittest.main()
