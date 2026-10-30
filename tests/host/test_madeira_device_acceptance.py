import hashlib
import importlib.util
import io
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(module_name, path):
    spec = importlib.util.spec_from_file_location(module_name, ROOT / "scripts" / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


device = load("acceptance", "verify_madeira_device_acceptance.py")
pe = load("guest_pe", "inspect_windows_game_pe.py")


def windows_pe(arch=0x8664, names=("d3d11.dll", "vcruntime140.dll")):
    data = bytearray(4096)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, arch, 1)
    struct.pack_into("<H", data, 0x94, 240)
    optional_offset = 0x98
    is64 = arch == 0x8664
    struct.pack_into("<H", data, optional_offset, 0x20B if is64 else 0x10B)
    directory_offset = optional_offset + (112 if is64 else 96)
    struct.pack_into("<I", data, directory_offset - 4, 16)
    struct.pack_into("<II", data, directory_offset + 8, 0x1100, (len(names) + 1) * 20)
    section = optional_offset + 240
    data[section:section + 8] = b".rdata\0\0"
    struct.pack_into("<IIII", data, section + 8, 0x800, 0x1000, 0x800, 0x400)
    for index, dll in enumerate(names):
        offset = 0x500 + index * 20
        struct.pack_into("<I", data, offset + 12, 0x1200 + index * 40)
        raw = dll.encode("ascii") + b"\0"
        data[0x600 + index * 40:0x600 + index * 40 + len(raw)] = raw
    return data


class MadeiraDeviceAndCompatibilityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.ipa = self.root / "signed.ipa"
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/iDeck.app/Info.plist", bytes(10_000))
        self.report = device.template("d3d11", False, False)
        self.report["build"].update({
            "commit": "a" * 40,
            "actions_run_url": "https://github.com/FacensPedro/iDeck/actions/runs/41010436630",
            "unsigned_ipa_sha256": "b" * 64,
            "signed_ipa_sha256": device.digest(self.ipa),
        })
        self.report["device"].update({
            "model": "iPad test device", "ipad_os_build": "26.0-test", "signing_team": "example",
        })
        self.report["signed_ipa"] = "signed.ipa"
        self.report["corresponding_source_url"] = "https://github.com/FacensPedro/iDeck"
        for name in self.report["checks"]:
            suffix = ".png" if name in ("guest_first_frame", "guest_subsequent_frames") else ".txt"
            data = (b"\x89PNG\r\n\x1a\n" if suffix == ".png" else b"DEVICE EVIDENCE\n") + bytes(500)
            file = self.root / (name + suffix)
            file.write_bytes(data)
            self.report["checks"][name] = {
                "status": "PASS", "evidence_file": file.name,
                "sha256": hashlib.sha256(data).hexdigest(),
            }

    def test_real_evidence_hashes_are_ready_for_manual_review_not_auto_success(self):
        errors, receipt = device.validate(self.report, self.root)
        self.assertEqual(errors, [])
        self.assertTrue(receipt["ready_for_human_review"])
        self.assertFalse(receipt["device_compatibility_proven_automatically"])
        self.assertEqual(receipt["integrity_verified"], receipt["required"])

    def test_iphone_duo_uses_generic_ios_metadata_with_manual_review(self):
        self.report["device"] = {
            "model": "iPhone Duo",
            "os_build": "27.1-test-fixture",
            "signing_team": "example",
        }
        errors, receipt = device.validate(self.report, self.root)
        self.assertEqual(errors, [])
        self.assertTrue(receipt["ready_for_human_review"])
        self.assertFalse(receipt["device_compatibility_proven_automatically"])

    def test_iphone_duo_without_ios_build_is_rejected(self):
        self.report["device"] = {
            "model": "iPhone Duo",
            "os_build": "",
            "signing_team": "example",
        }
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("iOS/iPadOS build" in issue for issue in errors))

    def test_not_run_or_missing_proof_rejects_device_acceptance(self):
        self.report["checks"]["guest_first_launch"]["status"] = "NOT RUN"
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("guest_first_launch" in error for error in errors))

    def test_tampered_guest_frame_is_detected(self):
        (self.root / "guest_first_frame.png").write_bytes(b"wrong data" * 90)
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("guest_first_frame" in error for error in errors))

    def test_d3d12_and_wow64_require_extra_live_device_proof(self):
        wanted = device.template("d3d12", True, True)
        self.assertIn("d3d12_guest_first_frame", wanted["checks"])
        self.assertIn("wow64_i386_guest_launch", wanted["checks"])
        self.assertIn("wow64_i386_d3d11_first_frame", wanted["checks"])
        self.assertIn("dotnet_mono_runtime", wanted["checks"])

    def test_wow64_cannot_pass_without_i386_guest_frame_recording(self):
        self.report["profile"]["wow64"] = True
        errors, receipt = device.validate(self.report, self.root)
        self.assertTrue(any("wow64_i386_d3d11_first_frame" in issue for issue in errors))
        self.assertFalse(receipt["ready_for_human_review"])

    def test_zip_escape_or_symlink_evidence_cannot_escape_root(self):
        self.report["checks"]["jit_attached"]["evidence_file"] = "../outside.txt"
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("jit_attached" in error for error in errors))

    def test_in_root_evidence_symlink_cannot_be_used_as_proof(self):
        target = self.root / "guest_first_launch.txt"
        link = self.root / "alias-to-evidence.txt"
        link.symlink_to(target)
        self.report["checks"]["guest_first_launch"]["evidence_file"] = link.name
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("guest_first_launch" in issue and "symbolic link" in issue
                            for issue in errors))

    def test_symlinked_subdirectory_cannot_be_used_as_proof(self):
        (self.root / "real-proofs").mkdir()
        target = self.root / "real-proofs" / "sample.txt"
        data = b"DEVICE EVIDENCE\\n" + bytes(500)
        target.write_bytes(data)
        (self.root / "shortcut").symlink_to(self.root / "real-proofs", target_is_directory=True)
        self.report["checks"]["guest_first_launch"] = {
            "status": "PASS",
            "evidence_file": "shortcut/sample.txt",
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("guest_first_launch" in issue and "symbolic link" in issue
                            for issue in errors))

    def test_fake_signed_ipa_hash_is_rejected(self):
        self.report["build"]["signed_ipa_sha256"] = "0" * 64
        errors, _ = device.validate(self.report, self.root)
        self.assertTrue(any("signed IPA hash" in error for error in errors))

    def test_x64_game_with_d3d11_and_vcruntime_imports(self):
        file = self.root / "game-x64.exe"
        file.write_bytes(windows_pe())
        result = pe.inspect(file)
        self.assertEqual(result["guest_architecture"], "x86_64")
        self.assertFalse(result["requires_wow64"])
        self.assertTrue(result["possible_runtime_requirements"]["d3d11"])
        self.assertTrue(result["possible_runtime_requirements"]["visual_cpp_runtime"])
        self.assertFalse(result["execution_verified"])

    def test_x86_game_with_d3d12_import_requires_wow64(self):
        file = self.root / "game-x86.exe"
        file.write_bytes(windows_pe(0x14C, ("d3d12.dll", "xinput1_3.dll")))
        result = pe.inspect(file)
        self.assertEqual(result["guest_architecture"], "x86")
        self.assertTrue(result["requires_wow64"])
        self.assertEqual(result["graphics_profile_hint"], "d3d12")
        self.assertTrue(result["possible_runtime_requirements"]["xinput"])

    def test_corrupt_executable_is_rejected(self):
        file = self.root / "game.exe"
        file.write_bytes(bytes(1024))
        with self.assertRaisesRegex(ValueError, "not a Windows"):
            pe.inspect(file)


if __name__ == "__main__":
    unittest.main()
