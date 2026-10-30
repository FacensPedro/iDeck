import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pe_inspector_delay", ROOT / "scripts/inspect_windows_game_pe.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def make_pe(path: Path, is_64: bool, delayed: str, regular: str):
    data = bytearray(2048)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    optional_size = 240 if is_64 else 224
    struct.pack_into("<HH", data, 0x84, 0x8664 if is_64 else 0x14C, 1)
    struct.pack_into("<H", data, 0x94, optional_size)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20B if is_64 else 0x10B)
    data_dir = 112 if is_64 else 96
    struct.pack_into("<I", data, optional + data_dir - 4, 16)
    struct.pack_into("<II", data, optional + data_dir + 8, 0x1100, 40)
    struct.pack_into("<II", data, optional + data_dir + 13 * 8, 0x1140, 64)
    section = optional + optional_size
    struct.pack_into("<IIII", data, section + 8, 0x400, 0x1000, 0x400, 0x200)
    struct.pack_into("<I", data, 0x300 + 12, 0x11C0)
    struct.pack_into("<II", data, 0x340, 1, 0x11E0)
    data[0x3C0:0x3C0 + len(regular) + 1] = regular.encode() + b"\0"
    data[0x3E0:0x3E0 + len(delayed) + 1] = delayed.encode() + b"\0"
    path.write_bytes(data)


class DelayedImportsTests(unittest.TestCase):
    def test_pe32_delayed_d3d12_requires_wow64(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "guest32.exe"
            make_pe(file, False, "D3D12.DLL", "kernel32.dll")
            report = module.inspect(file)
            self.assertTrue(report["requires_wow64"])
            self.assertEqual(report["delay_imports"], ["d3d12.dll"])
            self.assertTrue(report["possible_runtime_requirements"]["d3d12"])
            self.assertEqual(report["graphics_profile_hint"], "d3d12")

    def test_pe64_delayed_opengl_and_media(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "guest64.exe"
            make_pe(file, True, "opengl32.dll", "mfplat.dll")
            report = module.inspect(file)
            self.assertFalse(report["requires_wow64"])
            self.assertTrue(report["possible_runtime_requirements"]["opengl"])
            self.assertTrue(report["possible_runtime_requirements"]["media_foundation"])

    def test_invalid_va_delay_descriptor_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "invalid.exe"
            make_pe(file, False, "d3d11.dll", "kernel32.dll")
            data = bytearray(file.read_bytes())
            struct.pack_into("<I", data, 0x340, 0)
            file.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "VA-based PE delay import descriptor"):
                module.inspect(file)


if __name__ == "__main__":
    unittest.main()
