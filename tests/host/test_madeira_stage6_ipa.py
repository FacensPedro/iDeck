import importlib.util
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import subprocess

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "stage6_ipa", ROOT / "scripts/verify_madeira_stage6_ipa.py",
)
stage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage)


class MadeiraStage6IPATests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.temp = Path(directory.name)
        self.app = self.temp / "iDeck.app"
        self.ipa = self.temp / "iDeck.ipa"
        for relative in stage.IPA_PAYLOADS:
            path = self.app / relative.lstrip("/")
            path.parent.mkdir(parents=True, exist_ok=True)
            data = (relative + "\n").encode("utf-8") * 128
            if relative == "Info.plist":
                data = plistlib.dumps({"CFBundleIdentifier": "com.ideck.ideck"})
            elif relative == "PlugIns/VPNExtension.appex/Info.plist":
                data = plistlib.dumps({"CFBundleIdentifier": "com.ideck.ideck.VPNExtension"})
            elif relative == "MadeiraRuntimeManifest.plist":
                data = plistlib.dumps(stage.EXPECTED_MANIFEST)
            path.write_bytes(data)
        self.pack()

    def pack(self, extra=None):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for path in sorted(self.app.rglob("*")):
                if path.is_file():
                    archive.write(path, stage.ROOT + path.relative_to(self.app).as_posix())
            if extra:
                name, data, mode = extra
                item = zipfile.ZipInfo(stage.ROOT + name)
                item.create_system = 3
                item.external_attr = mode << 16
                archive.writestr(item, data)

    def check(self, drop_symbol=None):
        symbols = [s for s in stage.REQUIRED_SYMBOLS if s != drop_symbol]
        exports = "\n".join(f"0000000100000000 T _{s}" for s in symbols)
        def fake_run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "arm64\n" if "lipo" in args else exports, "")
        with patch.object(stage.subprocess, "run", side_effect=fake_run):
            return stage.inspect(self.app, self.ipa)

    def test_compiled_unsigned_d3d11_ipa_is_accepted_with_receipt(self):
        errors, receipt = self.check()
        self.assertEqual(errors, [])
        self.assertTrue(receipt["validated"])
        self.assertEqual(receipt["stage"], 6)
        self.assertEqual(len(receipt["ipa_sha256"]), 64)
        self.assertIn("StikDebug executable JIT mapping", receipt["not_validated"])

    def test_linked_wine_symbol_is_required_not_merely_a_file(self):
        errors, receipt = self.check(drop_symbol="wineserver_start")
        self.assertTrue(any("wineserver_start" in issue for issue in errors))
        self.assertFalse(receipt["validated"])

    def test_ipa_missing_guest_module_is_rejected(self):
        with zipfile.ZipFile(self.ipa) as original:
            archive_members = [(entry.filename, original.read(entry)) for entry in original.infolist()]
        with zipfile.ZipFile(self.ipa, "w") as new:
            for name, data in archive_members:
                if not name.endswith("/arm64ec-windows/d3d11.dll"):
                    new.writestr(name, data)
        errors, _ = self.check()
        self.assertTrue(any("d3d11.dll" in error for error in errors))

    def test_d3d12_proprietary_converter_asset_is_rejected(self):
        self.pack(("d3d12/libmetalirconverter.dylib", b"not permitted", stat.S_IFREG | 0o644))
        errors, _ = self.check()
        self.assertTrue(any("illegally includes D3D12/WoW64" in error for error in errors))

    def test_runtime_symlink_inside_ipa_is_rejected(self):
        self.pack(("MadeiraRuntime/arm64ec-windows/ntdll.link",
                   b"ntdll.dll", stat.S_IFLNK | 0o777))
        errors, _ = self.check()
        self.assertTrue(any("unsupported Unix symlink" in error for error in errors))

    def test_manifests_must_disallow_d3d12_and_wow64(self):
        path = self.app / "MadeiraRuntimeManifest.plist"
        path.write_bytes(plistlib.dumps({**stage.EXPECTED_MANIFEST, "d3d12Linked": True}))
        self.pack()
        errors, _ = self.check()
        self.assertTrue(any("d3d12Linked" in error for error in errors))

    def test_repacked_tampered_binary_is_rejected(self):
        with zipfile.ZipFile(self.ipa) as original:
            data = [(entry.filename, original.read(entry)) for entry in original.infolist()]
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for name, content in data:
                if name.endswith("/arm64ec-windows/xtajit64.dll"):
                    content = b"tampered" + content
                archive.writestr(name, content)
        errors, _ = self.check()
        self.assertTrue(any("differs from staged binary" in error for error in errors))

    def test_duplicate_zip_members_are_rejected(self):
        with zipfile.ZipFile(self.ipa, "a") as archive:
            archive.writestr(stage.ROOT + "MadeiraRuntimeManifest.plist", b"duplicated")
        errors, _ = self.check()
        self.assertTrue(any("duplicate ZIP entries" in error for error in errors))

    def test_risky_zip_path_is_rejected(self):
        self.pack(("../escape.dll", b"MZ", stat.S_IFREG | 0o644))
        errors, _ = self.check()
        self.assertTrue(any("unsafe or unexpected ZIP path" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
