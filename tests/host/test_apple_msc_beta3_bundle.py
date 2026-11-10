import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
from unittest.mock import patch
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
        for folder in (self.source / "d3d12", self.app / "d3d12"):
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
            for directory in ("d3d12",):
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
        (self.app / "d3d12" / msc.LICENSE_NAME).write_bytes(b"bad")
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
        for folder in (self.source / "d3d12", self.app / "d3d12"):
            for name, content in self.data.items():
                (folder / name).write_bytes(content)
        self.pack()
        errors = msc.verify(self.source, self.app, self.ipa)
        self.assertTrue(any("Mach-O" in error for error in errors))

    def test_valid_macho_but_incorrect_sdk_provenance_fails(self):
        receipt = json.loads(self.data[msc.PROVENANCE_NAME])
        receipt["sdk"] = "25.0.0"
        self.data[msc.PROVENANCE_NAME] = json.dumps(receipt).encode()
        for folder in (self.source / "d3d12", self.app / "d3d12"):
            (folder / msc.PROVENANCE_NAME).write_bytes(self.data[msc.PROVENANCE_NAME])
        self.pack()
        self.assertTrue(any("sdk" in error for error in msc.verify(self.source, self.app, self.ipa)))

    def test_missing_provenance_fails(self):
        (self.source / "d3d12" / msc.PROVENANCE_NAME).unlink()
        self.assertTrue(msc.verify(self.source, self.app, self.ipa))


@unittest.skipUnless(shutil.which("codesign") and shutil.which("xcrun"), "Requires macOS signing tools")
class AppleMSCResigningTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.source = root / "source"
        self.app = root / "iDeck.app"
        source_dir = self.source / "d3d12"
        app_dir = self.app / "d3d12"
        source_dir.mkdir(parents=True)
        app_dir.mkdir(parents=True)
        code = root / "converter.c"
        code.write_text('const char shader_test_marker[] = "original-shader-test"; int converter_test(void) { return 42; }')
        library = source_dir / msc.LIBRARY_NAME
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        subprocess.run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-dynamiclib",
                        "-isysroot", sdk, "-miphoneos-version-min=18.0", str(code), "-o", str(library)], check=True)
        self.sign(library, "original.converter")
        license_data = b"{\\rtf1 APPLE SOFTWARE LICENSE AGREEMENT}"
        details = msc.ios_macho_details(library)
        receipt = {"package_sha256": msc.PACKAGE_SHA256, "converter": "Apple Metal Shader Converter 4.0 beta 3",
                   "architecture": "arm64", "device_execution_verified": False, **details,
                   "library_bytes": library.stat().st_size, "library_sha256": msc.digest(library.read_bytes()),
                   "license_sha256": msc.digest(license_data)}
        for directory in (source_dir, app_dir):
            (directory / msc.LICENSE_NAME).write_bytes(license_data)
            (directory / msc.PROVENANCE_NAME).write_text(json.dumps(receipt))
        self.original = library
        self.staged = app_dir / msc.LIBRARY_NAME
        shutil.copyfile(library, self.staged)
        self.expected_bytes = library.stat().st_size

    def sign(self, file, identifier):
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identifier, str(file)],
                       check=True, capture_output=True)

    def verify(self):
        with patch.object(msc, "EXPECTED_IOS_LIBRARY_BYTES", self.expected_bytes):
            return msc.verify(self.source, self.app)

    def test_valid_resign_preserves_original_code(self):
        self.sign(self.staged, "ideck.replacement.converter.with.a.longer.identifier")
        self.assertNotEqual(self.original.read_bytes(), self.staged.read_bytes())
        self.assertEqual(self.verify(), [])

    def test_valid_signature_cannot_hide_changed_shader_code(self):
        data = self.staged.read_bytes()
        self.assertIn(b"original-shader-test", data)
        self.staged.write_bytes(data.replace(b"original-shader-test", b"modified-shader-test"))
        self.sign(self.staged, "ideck.modified.converter")
        self.assertTrue(any("audited code" in error for error in self.verify()))

    def test_invalid_signature_is_rejected(self):
        self.sign(self.staged, "ideck.replacement.converter")
        data = self.staged.read_bytes()
        self.staged.write_bytes(data.replace(b"original-shader-test", b"modified-shader-test"))
        self.assertTrue(self.verify())


if __name__ == "__main__":
    unittest.main()
