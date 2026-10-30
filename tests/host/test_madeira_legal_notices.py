import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "madeira_notices", ROOT / "scripts/verify_madeira_legal_notices.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MadeiraLegalNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ideck-legal-")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "iDeck.app"
        self.app.mkdir()
        for name, markers in module.NOTICE_FILES.items():
            notice = self.app / name
            notice.parent.mkdir(parents=True, exist_ok=True)
            notice.write_text("Real license source fixture\n" + "\n".join(markers) + "\n")

    def test_complete_open_source_notice_farm_for_d3d11(self):
        self.assertEqual(module.verify(self.app, "d3d11"), [])

    def test_missing_gpl_notice_rejected(self):
        (self.app / "legal/LICENSE").unlink()
        self.assertTrue(any("legal/LICENSE" in err for err in module.verify(self.app, "d3d11")))

    def test_mismatched_dxmt_license_rejected(self):
        (self.app / "licenses/DXMT-MIT.txt").write_text(
            "Not the original DXMT MIT license; this is a corrupted copy " * 2
        )
        self.assertTrue(any("DXMT-MIT" in err for err in module.verify(self.app, "d3d11")))

    def test_stray_metal_shader_converter_rejected(self):
        path = self.app / "Frameworks/Private/libmetalirconverter.dylib"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"not licensed")
        self.assertTrue(any("Converter" in err for err in module.verify(self.app, "d3d11")))

    def test_d3d12_directory_rejected_for_converter_free_profile(self):
        (self.app / "d3d12").mkdir()
        self.assertTrue(any("D3D12 directory" in err for err in module.verify(self.app, "d3d11")))

    def test_unknown_backend_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unsupported Madeira graphics"):
            module.verify(self.app, "auto")


if __name__ == "__main__":
    unittest.main()
