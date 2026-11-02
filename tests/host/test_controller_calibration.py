"""Run the actual portable XInput/HID stick calibration through the host C compiler."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = (ROOT / "iDeck/NativeRuntime/DirectInputBridge.mm").read_text(encoding="utf-8")
INPUT = (ROOT / "iDeck/InputManager.swift").read_text(encoding="utf-8")
HEADER = ROOT / "iDeck/NativeRuntime/GamepadResponse.h"

C_TEST = r"""
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "GamepadResponse.h"

int main(void) {
    IDeckPadStick zero = ideck_pad_stick(0.02f, 0.02f, 1.0f, 0.10f);
    assert(zero.x == 0 && zero.y == 0);

    IDeckPadStick full = ideck_pad_stick(1.0f, -1.0f, 1.0f, 0.0f);
    assert(full.x > 0 && full.y < 0);
    assert(fabsf((float)full.x - (float)-full.y) <= 2.0f);

    IDeckPadStick left = ideck_pad_stick(-1.0f, 0.0f, 1.0f, 0.0f);
    assert(left.x == INT16_MIN && left.y == 0);
    IDeckPadStick right = ideck_pad_stick(1.0f, 0.0f, 1.0f, 0.0f);
    assert(right.x == INT16_MAX && right.y == 0);

    IDeckPadStick analog = ideck_pad_stick(0.5f, 0.0f, 1.0f, 0.10f);
    assert(abs(analog.x - 14563) <= 2 && analog.y == 0);
    IDeckPadStick slow = ideck_pad_stick(0.5f, 0.0f, 0.5f, 0.10f);
    IDeckPadStick fast = ideck_pad_stick(0.5f, 0.0f, 2.0f, 0.10f);
    assert(slow.x < analog.x && analog.x < fast.x);

    IDeckPadStick diagonal = ideck_pad_stick(0.5f, 0.5f, 1.0f, 0.10f);
    assert(abs(diagonal.x - diagonal.y) <= 1);
    assert(hypotf(diagonal.x, diagonal.y) <= 32769.0f);

    IDeckPadStick sanitized = ideck_pad_stick(NAN, 0.8f, INFINITY, -1.0f);
    assert(sanitized.x == 0 && sanitized.y == 0);
    IDeckPadStick high = ideck_pad_stick(0.5f, 0.0f, 100.0f, 100.0f);
    assert(high.x >= 0 && high.x <= INT16_MAX);
    IDeckPadStick bounded = ideck_pad_stick(8.0f, -10.0f, 2.0f, 0.0f);
    assert(bounded.x > 0 && bounded.y < 0);
    puts("PASS: calibrated XInput/HID stick math");
    return 0;
}
"""


class ControllerCalibrationTests(unittest.TestCase):
    def test_native_stick_response_is_compiled_and_exercised(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if compiler is None:
            self.skipTest("C compiler is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "calibration.c"
            binary = Path(directory) / "calibration"
            main.write_text(C_TEST, encoding="utf-8")
            command = [compiler, "-std=c11", "-O2", "-Wall", "-Wextra",
                       "-Werror", "-I", str(HEADER.parent), str(main),
                       "-lm", "-o", str(binary)]
            build = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)

    def test_actual_xinput_and_hid_share_calibrated_axes(self):
        self.assertIn('#include "GamepadResponse.h"', BRIDGE)
        self.assertIn('ideck_pad_stick(pad.leftThumbstick.xAxis.value', BRIDGE)
        self.assertIn('ideck_pad_stick(pad.rightThumbstick.xAxis.value', BRIDGE)
        self.assertIn('g_leftSensitivity, g_stickDeadzone', BRIDGE)
        self.assertIn('g_rightSensitivity, g_stickDeadzone', BRIDGE)
        self.assertIn('state.lx = left.x; state.ly = left.y;', BRIDGE)
        self.assertIn('state.rx = right.x; state.ry = right.y;', BRIDGE)
        self.assertIn('hid.lx = state.lx; hid.ly = state.ly;', BRIDGE)
        self.assertIn('hid.rx = state.rx; hid.ry = state.ry;', BRIDGE)

    def test_live_settings_and_initial_output(self):
        for key in ('controllerLeftSensitivity', 'controllerRightSensitivity',
                    'controllerDeadzone'):
            self.assertIn(key, BRIDGE)
        self.assertIn('NSUserDefaultsDidChangeNotification', BRIDGE)
        self.assertIn('load_controller_response();', BRIDGE)
        self.assertIn('g_settingsObserver', BRIDGE)
        self.assertIn('output_active(g_appActive);', BRIDGE)
        self.assertIn('output_active(NO);', BRIDGE)
        self.assertIn('zero_vibration(i);', BRIDGE)
        self.assertIn('publish_pad(i, NULL);', BRIDGE)
        self.assertIn('if (battery && battery.batteryState != GCDeviceBatteryStateUnknown &&', BRIDGE)
        self.assertIn('GCController.controllers().filter { $0.extendedGamepad != nil }', INPUT)


if __name__ == "__main__":
    unittest.main()
