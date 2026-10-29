import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAD = (ROOT / "iDeck/NativeRuntime/DirectInputBridge.mm").read_text()
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
BRIDGE = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text()
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text()
INPUT = (ROOT / "iDeck/WineInputBridge.swift").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()
PROFILE = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text()
UPSTREAM_LINK = (ROOT / "scripts/link_madeira_native.sh").read_text()
FETCH = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
PATCH = (ROOT / "patches/madeira-repeat-wine-sessions.patch").read_text()


class MadeiraXInputHIDRestartTests(unittest.TestCase):
    def test_four_xinput_slots_and_hid_transport_are_real_native_snapshots(self):
        self.assertIn("IDECK_PAD_COUNT 4", PAD)
        self.assertIn("static_assert(sizeof(IDeckGamepad) == 20", PAD)
        self.assertIn("static_assert(sizeof(IDeckHIDPad) == 48", PAD)
        self.assertIn('"winios_gamepad_set_state"', PAD)
        self.assertIn('"winios_hidpad_set_state"', PAD)
        self.assertIn("GCControllerDidConnectNotification", PAD)
        self.assertIn("GCControllerDidDisconnectNotification", PAD)
        self.assertIn("g_slots[i] == controller", PAD)
        self.assertIn("GCController.controllers", PAD.replace("[GCController controllers]", "GCController.controllers"))
        self.assertIn("g_hidXInput", PAD)
        self.assertIn('setenv("MADEIRA_HIDPAD", kind, 1)', PAD)
        self.assertIn("publish_pad(i, NULL)", PAD)
        self.assertNotIn("SDL_GAMECONTROLLERCONFIG", INPUT)

    def test_xinput_hid_outputs_use_upstream_madeira_effects(self):
        for source in ("Winios/WiniosGamepad.c", "PadOutput.m"):
            self.assertIn(source, UPSTREAM_LINK)
        self.assertIn("-framework CoreHaptics", UPSTREAM_LINK)
        self.assertIn('"madeira_pad_output_set_slot"', PAD)
        self.assertIn('"madeira_pad_output_set_active"', PAD)
        self.assertIn('"madeira_pad_output_configure"', PAD)
        self.assertIn('"winios_gamepad_set_vibration"', PAD)
        self.assertIn("GCDeviceBatteryStateUnknown", PAD)
        self.assertIn("GCDualSenseGamepad", PAD)
        self.assertIn("GCDualShockGamepad", PAD)

    def test_gamepad_device_is_created_before_wineserver_and_disconnected_after(self):
        self.assertLess(NATIVE.index("ideck_gamepad_begin_session();"),
                        NATIVE.index("ideck_wineserver_initialize(wine_prefix)"))
        self.assertIn("ideck_gamepad_end_session();", NATIVE)
        self.assertIn("ideck_controller_stop()", (ROOT / "iDeck/NativeRuntime/RuntimeLifecycle.mm").read_text())
        self.assertIn('ideck_gamepad_begin_session(void)', HEADER)
        self.assertIn('ideck_gamepad_end_session(void)', HEADER)
        self.assertIn("WineGamepadEventClaim()", SESSION)
        self.assertIn(".handlesGameControllerEvents(matching: .gamepad)", INPUT)
        self.assertIn("ideck_controller_start()", INPUT)
        self.assertIn("ideck_controller_stop()", INPUT)

    def test_per_game_profile_modes_and_global_default(self):
        self.assertIn('controllerAPI: String = "Automatic"', PROFILE)
        self.assertIn('decodeIfPresent(String.self, forKey: .controllerAPI) ?? "Automatic"', PROFILE)
        self.assertIn('selection: $profile.controllerAPI', (ROOT / "iDeck/MainView.swift").read_text())
        self.assertIn('@AppStorage("wineControllerAPI")', SETTINGS)
        for choice in ('"XInput"', '"XInput + DirectInput"', '"HID"',
                       '"DualSense HID"', '"Generic HID"'):
            self.assertIn(choice, SETTINGS + (ROOT / "iDeck/MainView.swift").read_text())
        self.assertIn('setenv("MADEIRA_DINPUT_PAD", "1", 1)', ENVIRONMENT)
        self.assertIn('setenv("MADEIRA_PAD_MODE", "dualsense", 1)', ENVIRONMENT)
        self.assertIn('setenv("MADEIRA_PAD_MODE", "generic", 1)', ENVIRONMENT)

    def test_wineserver_restart_and_worker_completion_are_required(self):
        self.assertIn('int wine_process_thread_finished(void)', PATCH)
        self.assertIn('__atomic_store_n(&g_wine_thread_finished, 1, __ATOMIC_RELEASE)', PATCH)
        self.assertIn('__atomic_store_n(&g_wineserver_should_stop, 0, __ATOMIC_RELEASE)', PATCH)
        self.assertIn('git -C "$DEST" apply --check "$SESSION_PATCH"', FETCH)
        self.assertIn('"wine_process_thread_finished"', BRIDGE)
        self.assertIn("!ideck_wineprocess_thread_finished()", NATIVE)
        self.assertIn("ideck_wineprocess_thread_finished()", COORDINATOR)
        self.assertIn("ideck_wine_session_started = false", NATIVE)

    def test_upstream_patch_hunks_are_well_formed(self):
        hunks = re.findall(r"^@@ -(\d+),(\d+) \+(\d+),(\d+) @@([^\n]*)\n(.*?)(?=^@@ |^diff --git |\Z)",
                           PATCH, re.MULTILINE | re.DOTALL)
        self.assertGreaterEqual(len(hunks), 6)
        for _, old_len, _, new_len, _, body in hunks:
            lines = [line for line in body.splitlines() if line]
            old_count = sum(line[0] in (" ", "-") for line in lines)
            new_count = sum(line[0] in (" ", "+") for line in lines)
            self.assertEqual(old_count, int(old_len))
            self.assertEqual(new_count, int(new_len))


if __name__ == "__main__":
    unittest.main()
