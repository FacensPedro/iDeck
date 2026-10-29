import importlib.util
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("bundle", ROOT / "scripts/verify_madeira_bundle.py")
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


def make_64bit_pe(machine: int, chpe: bool = False) -> bytes:
    data = bytearray(4096)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x84, machine)
    struct.pack_into("<H", data, 0x86, 1)
    struct.pack_into("<H", data, 0x94, 240)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20B)
    struct.pack_into("<Q", data, optional + 24, 0x180000000)
    struct.pack_into("<I", data, optional + 60, 0x400)
    struct.pack_into("<I", data, optional + 108, 16)
    # IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG (10)
    if chpe:
        struct.pack_into("<II", data, optional + 192, 0x1000, 208)
    sections = optional + 240
    data[sections:sections + 8] = b".rdata\0\0"
    struct.pack_into("<IIII", data, sections + 8,
                     0x800, 0x1000, 0x800, 0x400)
    if chpe:
        struct.pack_into("<I", data, 0x400, 208)
        # IMAGE_LOAD_CONFIG_DIRECTORY64::CHPEMetadataPointer offset 0xC8
        struct.pack_into("<Q", data, 0x400 + 0xC8, 0x180000000 + 0x1200)
        struct.pack_into("<I", data, 0x600, 2)
    return bytes(data)


class MadeiraBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name)
        (self.app / "iDeck").write_bytes(b"fixture")
        for name in bundle.PE_FILES:
            arm64ec = name.startswith("arm64ec-windows/")
            for base in (self.app, self.app / "MadeiraRuntime"):
                path = base / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(make_64bit_pe(0x8664 if arm64ec else 0xAA64,
                                               chpe=arm64ec))
        for base in (self.app, self.app / "MadeiraRuntime"):
            converter = base / "d3d12/libmetalirconverter.dylib"
            converter.parent.mkdir(parents=True, exist_ok=True)
            converter.write_bytes(bytes(2048))
            locale = base / "nls/locale.nls"
            locale.parent.mkdir(parents=True, exist_ok=True)
            locale.write_bytes(b"locale-fixture")
        for base in (self.app, self.app / "MadeiraRuntime"):
            lua = base / "compat/love/lua51.dll"
            lua.parent.mkdir(parents=True, exist_ok=True)
            lua.write_bytes(make_64bit_pe(0x8664))
        (self.app / "prefix-template.tar.gz").write_bytes(b"\x1f\x8b" + bytes(2048))
        (self.app / "cacert.pem").write_bytes(b"-----BEGIN CERTIFICATE-----\nfixture")
        for folder in ("legal", "licenses"):
            (self.app / folder).mkdir()
        (self.app / "licenses/LuaJIT-MIT.txt").write_text(
            "LuaJIT MIT license fixture", encoding="utf-8"
        )
        for base in (self.app, self.app / "MadeiraRuntime"):
            for name in ("canary_vs.dxil", "canary_ps.dxil",
                         "canary_layout_vs.dxil", "canary_layout_ps.dxil"):
                (base / "d3d12" / name).write_bytes(b"DXIL-test")
        self.symbols = list(bundle.SYMBOLS)

    def inspect(self):
        output = "\n".join(f"00000000 T _{name}" for name in self.symbols)
        result = subprocess.CompletedProcess([], 0, stdout=output, stderr="")
        with patch.object(bundle.subprocess, "run", return_value=result):
            return bundle.inspect(self.app)

    def test_complete_static_fixture(self):
        self.assertEqual(self.inspect(), [])

    def test_rejects_native_d3d12_loader_mismatch(self):
        frontend = self.app / "arm64ec-windows/d3d12.dll"
        data = bytearray(frontend.read_bytes())
        data[-1] ^= 0x55
        frontend.write_bytes(data)
        self.assertTrue(any("D3D12 loader differs from Madeira native frontend" in e for e in self.inspect()))

    def test_missing_arm64ec_frontend(self):
        (self.app / "MadeiraRuntime/arm64ec-windows/d3d11.dll").unlink()
        self.assertTrue(any("missing compiled Windows PE" in error for error in self.inspect()))

    def test_missing_https_trust_store(self):
        (self.app / "cacert.pem").unlink()
        self.assertTrue(any("missing Madeira HTTPS certificate bundle" in e
                            for e in self.inspect()))

    def test_missing_d3d12_canary_shader(self):
        (self.app / "d3d12/canary_vs.dxil").unlink()
        self.assertTrue(any("missing D3D12 canary fixture" in e for e in self.inspect()))

    def test_missing_required_wow64_farm(self):
        output = "\n".join(f"00000000 T _{name}" for name in self.symbols)
        result = subprocess.CompletedProcess([], 0, stdout=output, stderr="")
        with patch.object(bundle.subprocess, "run", return_value=result):
            errors = bundle.inspect(self.app, require_wow64=True)
        self.assertTrue(any("missing WoW64 i386 library" in e for e in errors))

    def test_missing_root_level_wine_module(self):
        (self.app / "arm64ec-windows/kernel32.dll").unlink()
        self.assertTrue(any("arm64ec-windows/kernel32.dll" in error
                            for error in self.inspect()))

    def test_missing_display_export(self):
        self.symbols.remove("macdrv_functions")
        self.assertIn("native symbol not linked/exported: macdrv_functions", self.inspect())

    def test_missing_locale(self):
        (self.app / "nls/locale.nls").unlink()
        self.assertTrue(any("missing Wine locale resource" in e for e in self.inspect()))

    def test_rejects_plain_x64_module_in_arm64ec_directory(self):
        path = self.app / "MadeiraRuntime/arm64ec-windows/dxgi.dll"
        path.write_bytes(make_64bit_pe(0x8664))
        self.assertTrue(any("missing ARM64EC CHPE metadata" in error for error in self.inspect()))

    def test_rejects_coff_object_machine_in_final_pe(self):
        path = self.app / "MadeiraRuntime/arm64ec-windows/dxgi.dll"
        path.write_bytes(make_64bit_pe(0xA641))
        self.assertTrue(any("unexpected PE machine 0xa641" in error for error in self.inspect()))

    def test_rejects_bad_chpe_metadata_pointer(self):
        path = self.app / "MadeiraRuntime/arm64ec-windows/dxgi.dll"
        data = bytearray(path.read_bytes())
        struct.pack_into("<Q", data, 0x400 + 0xC8, 0x180000000 + 0x990000)
        path.write_bytes(data)
        self.assertTrue(any("invalid ARM64EC PE structure" in error for error in self.inspect()))

    def test_rejects_bad_chpe_metadata_version(self):
        path = self.app / "MadeiraRuntime/arm64ec-windows/dxgi.dll"
        data = bytearray(path.read_bytes())
        struct.pack_into("<I", data, 0x600, 0)
        path.write_bytes(data)
        self.assertTrue(any("invalid ARM64EC CHPE metadata version" in error
                            for error in self.inspect()))

    def test_rejects_x64_module_in_native_aarch64_directory(self):
        path = self.app / "MadeiraRuntime/aarch64-windows/dxgi.dll"
        path.write_bytes(make_64bit_pe(0x8664, chpe=True))
        self.assertTrue(any("unexpected PE machine 0x8664" in error for error in self.inspect()))

    def test_missing_readiness_symbol(self):
        self.symbols.remove("wineserver_is_ready")
        self.assertIn("native symbol not linked/exported: wineserver_is_ready", self.inspect())

    def test_required_input_and_shutdown_symbols_cannot_be_missing(self):
        for symbol in ("wine_process_thread_finished", "winios_post_key",
                       "winios_gamepad_set_state", "winios_hidpad_set_state"):
            with self.subTest(symbol=symbol):
                self.symbols = [name for name in bundle.SYMBOLS if name != symbol]
                self.assertIn(f"native symbol not linked/exported: {symbol}", self.inspect())

    def test_link_flags_retain_every_required_symbol(self):
        import sys
        result = subprocess.run([sys.executable, str(ROOT / "scripts/verify_madeira_bundle.py"),
                                 "--linker-flags"], check=True, text=True, capture_output=True)
        flags = result.stdout.split()
        self.assertIn("-Wl,-export_dynamic", flags)
        self.assertEqual(set(flags[1:]), {f"-Wl,-u,_{name}" for name in bundle.SYMBOLS})

    def test_missing_prefix_entrypoint(self):
        self.symbols.remove("madeira_seed_prefix_if_needed")
        self.assertIn("native symbol not linked/exported: madeira_seed_prefix_if_needed", self.inspect())

    def test_symbols_can_live_in_xcode_debug_dylib(self):
        (self.app / "iDeck.debug.dylib").write_bytes(b"fixture")
        all_symbols = "\n".join(f"00000000 T _{name}" for name in bundle.SYMBOLS)

        def nm_side_effect(command, **kwargs):
            output = all_symbols if str(command[-1]).endswith("iDeck.debug.dylib") else ""
            return subprocess.CompletedProcess(command, 0, stdout=output, stderr="")

        with patch.object(bundle.subprocess, "run", side_effect=nm_side_effect) as mocked:
            self.assertEqual(bundle.inspect(self.app), [])
            self.assertEqual(mocked.call_count, 2)

    def test_missing_debug_dylib_symbols_are_not_ignored(self):
        (self.app / "iDeck.debug.dylib").write_bytes(b"fixture")
        result = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(bundle.subprocess, "run", return_value=result):
            errors = bundle.inspect(self.app)
        self.assertTrue(any("native symbol not linked/exported" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
