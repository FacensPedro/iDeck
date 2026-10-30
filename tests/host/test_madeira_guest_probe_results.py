import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "device_guest_probes", ROOT / "scripts/verify_madeira_guest_probe_results.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class DeviceGuestProbeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.paths = {}
        for name, bits, pid in (
            ("smoke_x86_first", 32, 102),
            ("smoke_x86_second", 32, 103),
            ("smoke_x64_first", 64, 202),
            ("smoke_x64_second", 64, 203),
        ):
            self.add(name, f"ideck-guest-smoke=1 arch={bits} pid={pid}\n")
        for name, bits, pid in (
            ("audio_x86", 32, 104), ("audio_x64", 64, 204),
        ):
            text = (
                f"ideck_guest_probe=audio-input-v1\n"
                f"guest_arch={bits}\npid={pid}\n"
                "waveout_submitted=1\nwaveout_completed=1\n"
                "xinput_connected=1\nxinput_button_event=1\n"
                "touch_event=1\n"
            )
            self.add(name, text)
        for name in ("d3d11_x86", "d3d11_x64"):
            self.add(name, "ideck-d3d11-frame-probe: presents=180 hr=0x00000000\n")
        self.add("d3d12_x64", "ideck-d3d12-frame-probe: presents=120 hr=0x00000000 exit=0\n")

    def add(self, name, content):
        path = self.root / (name + ".log")
        path.write_text(content, encoding="utf-8")
        self.paths[name] = path.name

    def test_valid_probe_log_formats_are_only_human_review_candidates(self):
        receipt = module.audit(self.root, self.paths)
        self.assertEqual(receipt["logs_passing_format_and_reported_result_checks"], 9)
        self.assertFalse(receipt["device_execution_verified_automatically"])
        self.assertTrue(receipt["human_review_required"])
        self.assertEqual(receipt["findings"]["smoke_x86_first"]["arch"], 32)
        self.assertEqual(receipt["findings"]["d3d12_x64"]["presents"], 120)
        self.assertEqual(
            receipt["evidence"]["audio_x86"]["sha256"],
            hashlib.sha256((self.root / self.paths["audio_x86"]).read_bytes()).hexdigest(),
        )

    def test_a_failed_xinput_event_does_not_count_as_working_controller(self):
        self.add("audio_x86", (self.root / self.paths["audio_x86"]).read_text().replace(
            "xinput_button_event=1", "xinput_button_event=0"
        ))
        with self.assertRaisesRegex(ValueError, "xinput_button_event"):
            module.audit(self.root, self.paths)

    def test_waveout_submission_without_completion_is_not_audio_success(self):
        self.add("audio_x64", (self.root / self.paths["audio_x64"]).read_text().replace(
            "waveout_completed=1", "waveout_completed=0"
        ))
        with self.assertRaisesRegex(ValueError, "waveout_completed"):
            module.audit(self.root, self.paths)

    def test_reusing_first_session_is_not_a_second_launch(self):
        self.add("smoke_x86_second", (self.root / self.paths["smoke_x86_first"]).read_text())
        with self.assertRaisesRegex(ValueError, "same PID"):
            module.audit(self.root, self.paths)

    def test_incomplete_d3d12_frames_cannot_be_accepted(self):
        self.add("d3d12_x64", "ideck-d3d12-frame-probe: presents=119 hr=0x00000000 exit=0\n")
        with self.assertRaisesRegex(ValueError, "120 successful presents"):
            module.audit(self.root, self.paths)

    def test_failed_d3d11_presents_cannot_be_accepted(self):
        self.add("d3d11_x86", "ideck-d3d11-frame-probe: presents=180 hr=0x887a0005\n")
        with self.assertRaisesRegex(ValueError, "successful presents"):
            module.audit(self.root, self.paths)

    def test_symlinked_log_is_never_accepted(self):
        target = self.root / self.paths["audio_x86"]
        link = self.root / "alias.log"
        link.symlink_to(target)
        self.paths["audio_x86"] = link.name
        with self.assertRaisesRegex(ValueError, "symlinks"):
            module.audit(self.root, self.paths)

    def test_no_directory_traversal(self):
        self.paths["smoke_x64_first"] = "../some-other-file.log"
        with self.assertRaisesRegex(ValueError, "under the evidence directory"):
            module.audit(self.root, self.paths)

    def test_original_device_sources_use_actual_windows_apis(self):
        source = (ROOT / "tests/device/ideck_guest_audio_input_probe.c").read_text()
        for symbol in ("waveOutOpen(", "waveOutWrite(", "waveOutUnprepareHeader(",
                       "XInputGetState(", "WM_TOUCH", "WM_LBUTTONDOWN"):
            self.assertIn(symbol, source)
        d3d12 = (ROOT / "tests/device/ideck_d3d12_frame_probe.cpp").read_text()
        for symbol in ("D3D12CreateDevice(", "CreateCommandQueue(", "CreateSwapChainForHwnd(",
                       "ClearRenderTargetView(", "ExecuteCommandLists(", "Present("):
            self.assertIn(symbol, d3d12)
        builder = (ROOT / "scripts/build_madeira_device_probes.sh").read_text()
        self.assertIn("-lwinmm -lxinput9_1_0", builder)
        self.assertIn("-ld3d12 -ldxgi", builder)


if __name__ == "__main__":
    unittest.main()
