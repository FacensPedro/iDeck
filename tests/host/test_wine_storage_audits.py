import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WineStorageAuditTests(unittest.TestCase):
    def test_mono_and_gecko_duplicate_detection_is_read_only(self):
        audit = load("audit_wine_mono_gecko")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app = root / "iDeck.app"
            support = root / "support"
            prefix1, prefix2 = root / "prefix1", root / "prefix2"
            bundled = app / "wine-mono/bin/libmono-2.0-x86.dll"
            installed = support / "WineMono/wine-mono/bin/libmono-2.0-x86.dll"
            for path in (bundled, installed):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"same mono")
            for prefix in (prefix1, prefix2):
                file = prefix / ".cache/wine/wine-gecko-2.47.4-x86.msi"
                file.parent.mkdir(parents=True)
                file.write_bytes(b"same gecko")
            result = audit.audit(app, support, [prefix1, prefix2])
            self.assertEqual(len(result["identical_copies"]), 2)
            self.assertTrue(bundled.exists())
            self.assertTrue(installed.exists())

    def test_madeira_audit_reports_extra_architecture_files(self):
        audit = load("audit_madeira_v020_pe")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            madeira, ideck = root / "madeira", root / "ideck"
            for app in (madeira, ideck):
                folder = app / "arm64ec-windows"
                folder.mkdir(parents=True)
                (folder / "kernel32.dll").write_bytes(b"PE module")
            (ideck / "arm64ec-windows/extra.dll").write_bytes(b"additional")
            result = audit.audit(madeira, ideck, graphics="d3d11", wow64=False)
            self.assertIn("arm64ec-windows/extra.dll", result["extra_in_ideck"])
            self.assertEqual(result["architecture_sizes"]["arm64ec-windows"]["ideck_files"], 2)


if __name__ == "__main__":
    unittest.main()
