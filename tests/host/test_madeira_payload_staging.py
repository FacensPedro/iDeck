import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
STAGER = ROOT / "scripts" / "stage_madeira_payload.sh"

ARM64EC = (
    "ntdll.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll",
    "d3d12.dll", "d3d12core.dll", "xtajit64.dll", "winemetal.dll",
    "kernel32.dll", "kernelbase.dll", "user32.dll", "gdi32.dll",
    "ws2_32.dll", "d3d9.dll", "vulkan-1.dll", "madeira_d3d12.dll",
    "dcomp.dll", "ktmw32.dll", "faultrep.dll", "xaudio2_7.dll",
    "d3dx11_43.dll", "d3dcompiler_47.dll", "dinput8.dll",
)
ARM64 = ("d3d11.dll", "dxgi.dll", "winemetal.dll", "kernel32.dll", "user32.dll")
NOTICES = (
    "NOTICE.txt", "METAL-SHADER-CONVERTER-AGREEMENT.txt",
    "LICENSE-metal-shader-converter-headers.txt",
)


class MadeiraPayloadStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.source = base / "madeira" / "app" / "Madeira"
        self.app = base / "iDeck.app"
        self.app.mkdir()
        # Each runtime file is staged once, as a real file at the top level.
        self.assertFalse((self.app / "MadeiraRuntime").exists())
        for directory, names in (
            ("aarch64-windows", ARM64),
            ("arm64ec-windows", ARM64EC),
        ):
            for name in names:
                self.assertEqual(
                    (self.app / directory / name).read_bytes(),
                    (self.source / directory / name).read_bytes(),
                )
        converter = self.app / "d3d12" / "libmetalirconverter.dylib"
        self.assertTrue(converter.is_file())
        self.assertFalse(converter.is_symlink())
        self.assertEqual(
            (self.app / "cacert.pem").read_bytes(),
            (self.source / "cacert.pem").read_bytes(),
        )
        for name in ("canary_vs.dxil", "canary_ps.dxil",
                     "canary_layout_vs.dxil", "canary_layout_ps.dxil"):
            self.assertEqual(
                (self.app / "d3d12" / name).read_bytes(),
                (self.source / "d3d12" / name).read_bytes(),
            )
        for path in self.app.rglob("*"):
            self.assertFalse(path.is_symlink(), str(path))
        self.assertEqual(
            (self.app / "nls/locale.nls").read_bytes(),
            (self.source / "nls/locale.nls").read_bytes(),
        )
        self.assertEqual(
            (self.app / "prefix-template.tar.gz").read_bytes(),
            (self.source / "prefix-template.tar.gz").read_bytes(),
        )


if __name__ == "__main__":
    unittest.main()
