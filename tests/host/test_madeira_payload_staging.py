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
        for directory, names in (
            ("aarch64-windows", ARM64),
            ("arm64ec-windows", ARM64EC),
        ):
            folder = self.source / directory
            folder.mkdir(parents=True)
            for name in names:
                (folder / name).write_bytes(b"MZ" + bytes(128))
        (self.source / "cacert.pem").write_bytes(b"-----BEGIN CERTIFICATE-----\nfixture")
        for folder in ("legal", "licenses"):
            (self.source / folder).mkdir()
            (self.source / folder / "NOTICE.txt").write_text("Madeira notice", encoding="utf-8")
        compat = self.source / "compat" / "love"
        compat.mkdir(parents=True)
        (compat / "lua51.dll").write_bytes(b"MZ" + bytes(128))
        (self.source / "licenses" / "LuaJIT-MIT.txt").write_text(
            "LuaJIT MIT license fixture", encoding="utf-8",
        )
        (self.source / "nls").mkdir()
        (self.source / "nls" / "locale.nls").write_bytes(b"nls-data")
        (self.source / "prefix-template.tar.gz").write_bytes(
            b"\x1f\x8b" + bytes(64)
        )
        converter = self.source / "d3d12"
        converter.mkdir()
        (converter / "libmetalirconverter.dylib").write_bytes(b"converter-fixture")
        for notice in NOTICES:
            (converter / notice).write_text(notice, encoding="utf-8")
        for name in ("canary_vs.dxil", "canary_ps.dxil",
                     "canary_layout_vs.dxil", "canary_layout_ps.dxil"):
            (converter / name).write_bytes(b"DXIL-test")

    def test_d3d11_stages_without_redistributing_converter_or_d3d12(self):
        # A clean upstream Wine farm may already contain 32-bit/host WoW64.
        # This profile must discard those files even when they are present.
        i386 = self.source / "i386-windows"
        i386.mkdir()
        for name in ("ntdll.dll", "kernel32.dll", "user32.dll", "d3d11.dll", "dxgi.dll"):
            (i386 / name).write_bytes(b"MZ" + bytes(128))
        for name in ("xtajit.dll", "wow64.dll", "wow64win.dll"):
            (self.source / "aarch64-windows" / name).write_bytes(b"MZ" + bytes(128))
        environment = dict(os.environ)
        environment.update({
            "IDECK_MADEIRA_APP_ROOT": str(self.source),
            "IDECK_MADEIRA_GRAPHICS": "d3d11",
            "IDECK_BUILD_WOW64": "0",
            "IDECK_ACCEPT_METAL_CONVERTER_LICENSE": "0",
        })
        environment.pop("IDECK_CODESIGN_IDENTITY", None)
        subprocess.run(
            ["bash", str(STAGER), str(self.app)],
            env=environment, check=True, text=True, capture_output=True,
        )
        self.assertFalse((self.app / "d3d12").exists())
        self.assertFalse((self.app / "MadeiraRuntime/d3d12").exists())
        for prefix in (self.app, self.app / "MadeiraRuntime"):
            self.assertFalse((prefix / "i386-windows").exists())
            for name in ("xtajit.dll", "wow64.dll", "wow64win.dll"):
                self.assertFalse((prefix / "aarch64-windows" / name).exists())
        self.assertTrue((self.source / "i386-windows/ntdll.dll").is_file())
        self.assertTrue((self.source / "aarch64-windows/wow64.dll").is_file())
        for folder in ("aarch64-windows", "arm64ec-windows"):
            for name in ("d3d12.dll", "d3d12core.dll", "madeira_d3d12.dll"):
                self.assertFalse((self.app / folder / name).exists())
                self.assertFalse((self.app / "MadeiraRuntime" / folder / name).exists())
        for name in ("d3d11.dll", "dxgi.dll", "winemetal.dll"):
            self.assertTrue((self.app / "arm64ec-windows" / name).is_file())
            self.assertTrue((self.app / "MadeiraRuntime/arm64ec-windows" / name).is_file())
        self.assertTrue((self.source / "d3d12/libmetalirconverter.dylib").is_file())

    def test_d3d11_rejects_explicit_wow64_option(self):
        env = dict(os.environ)
        env.update({
            "IDECK_MADEIRA_APP_ROOT": str(self.source),
            "IDECK_MADEIRA_GRAPHICS": "d3d11",
            "IDECK_BUILD_WOW64": "1",
            "IDECK_ACCEPT_METAL_CONVERTER_LICENSE": "0",
        })
        result = subprocess.run(
            ["bash", str(STAGER), str(self.app)],
            env=env, capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("forbids WoW64", result.stderr)

    def test_vcruntime_requires_all_supplied_files(self):
        source = self.source / "x86_64-vcruntime"
        source.mkdir()
        (source / "vcruntime140.dll").write_bytes(b"MZ" + bytes(128))
        environment = dict(os.environ)
        environment.update({
            "IDECK_MADEIRA_APP_ROOT": str(self.source),
            "IDECK_ACCEPT_METAL_CONVERTER_LICENSE": "1",
        })
        result = subprocess.run(
            ["bash", str(STAGER), str(self.app)],
            env=environment, check=False, text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete Microsoft VC++ runtime", result.stderr)

    def test_native_payload_has_no_madeira_symlinks(self):
        environment = dict(os.environ)
        environment.update({
            "IDECK_MADEIRA_APP_ROOT": str(self.source),
            "IDECK_ACCEPT_METAL_CONVERTER_LICENSE": "1",
        })
        environment.pop("IDECK_CODESIGN_IDENTITY", None)
        subprocess.run(
            ["bash", str(STAGER), str(self.app)],
            env=environment, check=True, text=True, capture_output=True,
        )
        for directory, names in (
            ("aarch64-windows", ARM64),
            ("arm64ec-windows", ARM64EC),
        ):
            canonical = self.app / directory
            mirror = self.app / "MadeiraRuntime" / directory
            self.assertTrue(mirror.is_dir())
            self.assertFalse(mirror.is_symlink())
            for name in names:
                self.assertEqual(
                    (canonical / name).read_bytes(), (mirror / name).read_bytes()
                )
        self.assertEqual(
            (self.app / "compat/love/lua51.dll").read_bytes(),
            (self.app / "MadeiraRuntime/compat/love/lua51.dll").read_bytes(),
        )
        canonical_converter = self.app / "d3d12" / "libmetalirconverter.dylib"
        mirror_converter = (
            self.app / "MadeiraRuntime" / "d3d12" / "libmetalirconverter.dylib"
        )
        self.assertTrue(mirror_converter.is_file())
        self.assertFalse(mirror_converter.is_symlink())
        self.assertEqual(canonical_converter.read_bytes(), mirror_converter.read_bytes())
        self.assertEqual(
            (self.app / "cacert.pem").read_bytes(),
            (self.source / "cacert.pem").read_bytes(),
        )
        for name in ("canary_vs.dxil", "canary_ps.dxil",
                     "canary_layout_vs.dxil", "canary_layout_ps.dxil"):
            self.assertEqual(
                (self.app / "MadeiraRuntime/d3d12" / name).read_bytes(),
                (self.source / "d3d12" / name).read_bytes(),
            )
        for path in (self.app / "MadeiraRuntime").rglob("*"):
            self.assertFalse(path.is_symlink(), str(path))
        self.assertEqual(
            (self.app / "MadeiraRuntime/nls/locale.nls").read_bytes(),
            (self.source / "nls/locale.nls").read_bytes(),
        )
        self.assertEqual(
            (self.app / "prefix-template.tar.gz").read_bytes(),
            (self.source / "prefix-template.tar.gz").read_bytes(),
        )


if __name__ == "__main__":
    unittest.main()
