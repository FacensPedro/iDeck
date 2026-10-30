import hashlib
import importlib.util
import json
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "msc_bundle", ROOT / "scripts/verify_apple_msc_beta3_bundle.py"
)
msc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(msc)


class AppleMSCBundleTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.source = self.root / "upstream"
        self.app = self.root / "iDeck.app"
        self.ipa = self.root / "iDeck.ipa"
        header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, 1, 24, 0, 0)
        build = struct.pack("<IIIIII", 0x32, 24, 2, 13 << 16, (26 << 16) | (4 << 8), 0)
        library = (header + build).ljust(msc.EXPECTED_IOS_LIBRARY_BYTES, b"\0")
        license_data = b"{\\rtf1 APPLE SOFTWARE LICENSE AGREEMENT}" * 200
        receipt = {
            "package_sha256": msc.PACKAGE_SHA256,
            "converter": "Apple Metal Shader Converter 4.0 beta 3",
            "architecture": "arm64",
            "device_execution_verified": False,
            "platform": "iOS",
            "minimum_ios": "13.0.0",
            "sdk": "26.4.0",
            "library_bytes": msc.EXPECTED_IOS_LIBRARY_BYTES,
            "library_sha256": hashlib.sha256(library).hexdigest(),
            "license_sha256": hashlib.sha256(license_data).hexdigest(),
        }
        self.data = {
            msc.LIBRARY_NAME: library,
            msc.LICENSE_NAME: license_data,
            msc.PROVENANCE_NAME: json.dumps(receipt).encode(),
        }
        for folder in (self.source / "d3d12", self.app / "d3d12", self.app / "MadeiraRuntime/d3d12"):
            folder.mkdir(parents=True)
            for name, content in self.data.items():
                (folder / name).write_bytes(content)
        self.pack()

    def pack(self):
        with zipfile.ZipFile(self.ipa, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
            archive.writestr(
                "Payload/iDeck.app/MadeiraRuntimeManifest.plist",
                plistlib.dumps({"graphicsBackend": "d3d12", "d3d12Linked": True}),
            )
            for directory in ("d3d12", "MadeiraRuntime/d3d12"):
                for name, content in self.data.items():
                    archive.writestr(f"Payload/iDeck.app/{directory}/{name}", content)

    def test_matching_source_app_and_ipa_passes(self):
        self.assertEqual(msc.verify(self.source, self.app, self.ipa), [])

    def test_tampered_staged_library_fails(self):
        (self.app / "d3d12" / msc.LIBRARY_NAME).write_bytes(b"tampered" * 2_000_000)
        self.assertTrue(msc.verify(self.source, self.app, self.ipa))

    def test_wrong_package_hash_fails(self):
        path = self.source / "d3d12" / msc.PROVENANCE_NAME
        value = json.loads(path.read_text())
        value["package_sha256"] = "f" * 64
        path.write_text(json.dumps(value))
        self.assertTrue(msc.verify(self.source, self.app, self.ipa))

    def test_tampered_license_fails(self):
        (self.app / "MadeiraRuntime/d3d12" / msc.LICENSE_NAME).write_bytes(b"bad")
        self.assertTrue(msc.verify(self.source, self.app, self.ipa))

    def test_wrong_profile_fails(self):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(
                "Payload/iDeck.app/MadeiraRuntimeManifest.plist",
                plistlib.dumps({"graphicsBackend": "d3d11", "d3d12Linked": False}),
            )
        self.assertTrue(msc.verify(self.source, self.app, self.ipa))

    def test_matching_hashes_cannot_hide_non_macho_library(self):
        invalid = b"NOT-MACH-O" + bytes(msc.EXPECTED_IOS_LIBRARY_BYTES - 10)
        self.data[msc.LIBRARY_NAME] = invalid
        receipt = json.loads(self.data[msc.PROVENANCE_NAME])
        receipt["library_sha256"] = hashlib.sha256(invalid).hexdigest()
        self.data[msc.PROVENANCE_NAME] = json.dumps(receipt).encode()
        for folder in (self.source / "d3d12", self.app / "d3d12", self.app / "MadeiraRuntime/d3d12"):
            for name, content in self.data.items():
                (folder / name).write_bytes(content)
        self.pack()
        errors = msc.verify(self.source, self.app, self.ipa)
        self.assertTrue(any("Mach-O" in error for error in errors))

    def test_valid_macho_but_incorrect_sdk_provenance_fails(self):
        receipt = json.loads(self.data[msc.PROVENANCE_NAME])
        receipt["sdk"] = "25.0.0"
        self.data[msc.PROVENANCE_NAME] = json.dumps(receipt).encode()
        for folder in (self.source / "d3d12", self.app / "d3d12", self.app / "MadeiraRuntime/d3d12"):
            (folder / msc.PROVENANCE_NAME).write_bytes(self.data[msc.PROVENANCE_NAME])
        self.pack()
        self.assertTrue(any("sdk" in error for error in msc.verify(self.source, self.app, self.ipa)))

    def test_missing_provenance_fails(self):
        (self.source / "d3d12" / msc.PROVENANCE_NAME).unlink()
        self.assertTrue(msc.verify(self.source, self.app, self.ipa))


if __name__ == "__main__":
    unittest.main()
