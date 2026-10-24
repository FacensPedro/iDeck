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


class MadeiraBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name)
        (self.app / "iDeck").write_bytes(b"fixture")
        for name in bundle.PE_FILES:
            path = self.app / "MadeiraRuntime" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            data = bytearray(2048)
            data[:2] = b"MZ"
            struct.pack_into("<I", data, 0x3c, 128)
            data[128:132] = b"PE\0\0"
            struct.pack_into("<H", data, 132, 0xA641 if name.startswith("arm64ec") else 0xAA64)
            path.write_bytes(data)
        converter = self.app / "MadeiraRuntime/d3d12/libmetalirconverter.dylib"
        converter.parent.mkdir()
        converter.write_bytes(bytes(2048))
        (self.app / "prefix-template.tar.gz").write_bytes(b"\x1f\x8b" + bytes(2048))
        self.symbols = list(bundle.SYMBOLS)

    def inspect(self):
        output = "\n".join(f"00000000 T _{name}" for name in self.symbols)
        result = subprocess.CompletedProcess([], 0, stdout=output, stderr="")
        with patch.object(bundle.subprocess, "run", return_value=result):
            return bundle.inspect(self.app)

    def test_complete_static_fixture(self):
        self.assertEqual(self.inspect(), [])

    def test_missing_arm64ec_frontend(self):
        (self.app / "MadeiraRuntime/arm64ec-windows/d3d11.dll").unlink()
        self.assertTrue(any("missing compiled Windows PE" in error for error in self.inspect()))

    def test_wrong_frontend_architecture(self):
        path = self.app / "MadeiraRuntime/arm64ec-windows/dxgi.dll"
        data = bytearray(path.read_bytes())
        struct.pack_into("<H", data, 132, 0x8664)
        path.write_bytes(data)
        self.assertTrue(any("unexpected PE machine" in error for error in self.inspect()))

    def test_missing_readiness_symbol(self):
        self.symbols.remove("wineserver_is_ready")
        self.assertIn("native symbol not linked/exported: wineserver_is_ready", self.inspect())

    def test_missing_prefix_entrypoint(self):
        self.symbols.remove("madeira_seed_prefix_if_needed")
        self.assertIn("native symbol not linked/exported: madeira_seed_prefix_if_needed", self.inspect())


if __name__ == "__main__":
    unittest.main()
