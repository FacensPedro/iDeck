import importlib.util
import plistlib
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("madeira_bundle", ROOT / "scripts/verify_madeira_bundle.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def pe(machine: int, chpe: bool = False) -> bytes:
    data = bytearray(4096)
    data[0:2] = b"MZ"
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
    if chpe:
        struct.pack_into("<II", data, optional + 192, 0x1000, 208)
    sections = optional + 240
    data[sections:sections + 8] = b".rdata\0\0"
    struct.pack_into("<IIII", data, sections + 8, 0x800, 0x1000, 0x800, 0x400)
    if chpe:
        struct.pack_into("<I", data, 0x400, 208)
        struct.pack_into("<Q", data, 0x400 + 0xC8, 0x180000000 + 0x1200)
        struct.pack_into("<I", data, 0x600, 2)
    return bytes(data)


class MadeiraD3D11ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name)
        (self.app / "iDeck").write_bytes(b"fixture")
        for base in (self.app, self.app / "MadeiraRuntime"):
            for name in module.PE_FILES:
                if name in module.D3D12_PE_FILES:
                    continue
                dll = base / name
                dll.parent.mkdir(parents=True, exist_ok=True)
                arm64ec = name.startswith("arm64ec-windows/")
                dll.write_bytes(pe(0x8664 if arm64ec else 0xAA64, arm64ec))
            (base / "compat/love").mkdir(parents=True, exist_ok=True)
            (base / "compat/love/lua51.dll").write_bytes(pe(0x8664))
            (base / "vulkan/arm64ec-windows").mkdir(parents=True, exist_ok=True)
            for name in ("winevulkan.dll", "vulkan-1.dll"):
                (base / "vulkan/arm64ec-windows" / name).write_bytes(pe(0x8664, True))
            (base / "nls").mkdir(exist_ok=True)
            (base / "nls/locale.nls").write_text("valid")
        (self.app / "gl").mkdir()
        for name in ("libMoltenVK.dylib", "libOSMesa.dylib"):
            (self.app / "gl" / name).write_bytes(bytes.fromhex("cffaedfe0c000001") + bytes(64))
        (self.app / "cacert.pem").write_bytes(b"-----BEGIN CERTIFICATE-----\nfixture")
        (self.app / "prefix-template.tar.gz").write_bytes(b"\x1f\x8b" + bytes(2048))
        for name in ("legal", "licenses"):
            (self.app / name).mkdir()
        (self.app / "licenses/LuaJIT-MIT.txt").write_text("MIT")
        self.symbols = [name for name in module.SYMBOLS if name not in module.D3D12_SYMBOLS]

    def inspect(self, graphics="d3d11", require_wow64=False):
        output = "\n".join(f"00000000 T _{name}" for name in self.symbols)
        nm = subprocess.CompletedProcess([], 0, stdout=output, stderr="")
        with patch.object(module.subprocess, "run", return_value=nm):
            return module.inspect(self.app, graphics=graphics, require_wow64=require_wow64)

    def test_strict_d3d11_accepts_complete_fex_wine_dxmt_without_converter(self):
        self.assertEqual(self.inspect(), [])

    def test_d3d12_profile_still_rejects_missing_converter_and_pe(self):
        errors = self.inspect("d3d12")
        self.assertTrue(any("missing compiled Windows PE library" in error for error in errors))
        self.assertTrue(any("missing or empty iOS shader converter" in error for error in errors))

    def test_d3d11_fails_without_dxmt_frontend(self):
        (self.app / "MadeiraRuntime/arm64ec-windows/d3d11.dll").unlink()
        self.assertTrue(any("d3d11.dll" in error for error in self.inspect()))

    def test_d3d11_fails_without_fex_or_wine_symbol(self):
        for symbol in ("fex_initialize", "wineserver_start", "madeira_get_present_count"):
            with self.subTest(symbol=symbol):
                self.symbols.remove(symbol)
                self.assertTrue(any(symbol in error for error in self.inspect()))
                self.symbols.append(symbol)

    def test_d3d11_fails_if_converter_exists_anywhere_in_app(self):
        nested = self.app / "Resources/Unused/libmetalirconverter.dylib"
        nested.parent.mkdir(parents=True)
        nested.write_bytes(b"proprietary")
        self.assertTrue(any("Apple converter" in error for error in self.inspect()))

    def test_d3d11_fails_if_d3d12_pe_is_staged(self):
        for folder in ("arm64ec-windows", "aarch64-windows"):
            with self.subTest(folder=folder):
                path = self.app / folder / "d3d12.dll"
                path.write_bytes(pe(0x8664 if folder == "arm64ec-windows" else 0xAA64))
                self.assertTrue(any("must not bundle D3D12" in error for error in self.inspect()))
                path.unlink()

    def test_d3d11_fails_if_d3d12_payload_directory_exists(self):
        (self.app / "MadeiraRuntime/d3d12").mkdir()
        self.assertTrue(any("D3D12 payload directory" in error for error in self.inspect()))

    def test_d3d11_rejects_wow64_pe_tree(self):
        for relative in ("i386-windows", "MadeiraRuntime/i386-windows"):
            with self.subTest(path=relative):
                directory = self.app / relative
                directory.mkdir()
                (directory / "ntdll.dll").write_bytes(pe(0x8664))
                self.assertTrue(any("must not bundle WoW64" in err for err in self.inspect()))
                (directory / "ntdll.dll").unlink()
                directory.rmdir()

    def test_d3d11_rejects_wow64_host_modules(self):
        for root in (self.app, self.app / "MadeiraRuntime"):
            for name in ("xtajit.dll", "wow64.dll", "wow64win.dll"):
                with self.subTest(name=name, root=root.name):
                    path = root / "aarch64-windows" / name
                    path.write_bytes(pe(0xAA64))
                    self.assertTrue(any("must not bundle WoW64" in err for err in self.inspect()))
                    path.unlink()

    def test_d3d11_requires_real_i386_pe_and_host_modules_for_wow64(self):
        self.assertTrue(any(
            "missing WoW64 i386 library" in err
            for err in self.inspect(require_wow64=True)
        ))

    def test_linker_flags_exclude_only_optional_canary(self):
        command = ["python3", str(ROOT / "scripts/verify_madeira_bundle.py"),
                   "--linker-flags", "--graphics", "d3d11"]
        flags = subprocess.run(command, capture_output=True, text=True, check=True).stdout
        self.assertNotIn("-Wl,-u,_madeira_d3d12_canary_run", flags)
        self.assertIn("-Wl,-u,_madeira_get_present_count", flags)
        self.assertIn("-Wl,-u,_fex_initialize", flags)
        self.assertEqual(module.D3D12_SYMBOLS, ("madeira_d3d12_canary_run",))
        self.assertIn("madeira_get_present_count", module.SYMBOLS)


if __name__ == "__main__":
    unittest.main()
