import bz2
import gzip
import hashlib
import importlib.util
import io
import struct
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("apple_msc_beta3", ROOT / "scripts/prepare_apple_msc_beta3.py")
msc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(msc)


def cpio(name: str, data: bytes) -> bytes:
    fields = [0, 0, 0o100644, 0, 0, 1, 0]
    header = "070707" + "".join(f"{value:06o}" for value in fields)
    header += f"{0:011o}{len(name) + 1:06o}{len(data):011o}"
    assert len(header) == 76
    return header.encode() + name.encode() + b"\0" + data


def macho(arch=0x0100000C, platform=2):
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, arch, 0, 6, 1, 24, 0, 0)
    command = struct.pack("<IIIIII", 0x32, 24, platform, 13 << 16, (26 << 16) | (4 << 8), 0)
    return header + command + bytes(11_000_000)


def package(path: Path, library: bytes, license_text=b"APPLE SOFTWARE LICENSE AGREEMENT FOR METAL SHADER CONVERTER"):
    license_compressed = bz2.compress(license_text)
    payload = gzip.compress(
        cpio(msc.IOS_LIBRARY, library) +
        cpio("TRAILER!!!", b""),
        compresslevel=1,
    )
    toc = ET.Element("xar")
    files = ET.SubElement(toc, "toc")

    def entry(parent, name, data=None, compressed=False, offset=0):
        file = ET.SubElement(parent, "file")
        ET.SubElement(file, "name").text = name
        if data is not None:
            item = ET.SubElement(file, "data")
            ET.SubElement(item, "offset").text = str(offset)
            ET.SubElement(item, "length").text = str(len(data))
            ET.SubElement(item, "encoding", {"style": "application/x-bzip2" if compressed else "application/octet-stream"})
        return file

    resources = entry(files, "Resources")
    english = entry(resources, "English.lproj")
    entry(english, "License.rtf", license_compressed, compressed=True)
    converter = entry(files, "MetalShaderConverter.pkg")
    entry(converter, "Payload", payload, offset=len(license_compressed))
    xml = ET.tostring(toc)
    compressed_toc = zlib.compress(xml)
    header = struct.pack(">4sHHQQI", b"xar!", 28, 1, len(compressed_toc), len(xml), 1)
    path.write_bytes(header + compressed_toc + license_compressed + payload)


class AppleMSC4Beta3PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pkg = self.root / "Apple.pkg"
        self.out = self.root / "d3d12"
        package(self.pkg, macho())

    def prepare(self, accept=True):
        with patch.object(msc, "PACKAGE_SHA256", msc.digest(self.pkg)):
            return msc.prepare(self.pkg, self.out, accept)

    def test_audited_ios_arm64_library_license_and_receipt_are_staged(self):
        receipt = self.prepare()
        self.assertEqual(receipt["architecture"], "arm64")
        self.assertEqual(receipt["platform"], "iOS")
        self.assertEqual(receipt["minimum_ios"], "13.0.0")
        self.assertEqual(receipt["sdk"], "26.4.0")
        self.assertFalse(receipt["device_execution_verified"])
        self.assertEqual(msc.digest(self.out / msc.LIBRARY_NAME), receipt["library_sha256"])
        self.assertTrue((self.out / msc.LICENSE_NAME).is_file())
        self.assertTrue((self.out / msc.PROVENANCE_NAME).is_file())
        self.assertFalse((self.out / "metal-shaderconverter").exists())
        self.assertFalse((self.out / "Apple.pkg").exists())

    def test_requires_explicit_apple_license_acceptance(self):
        with self.assertRaisesRegex(ValueError, "acknowledge-license"):
            self.prepare(False)

    def test_rejects_an_unknown_package_hash(self):
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            msc.prepare(self.pkg, self.out, True)

    def test_refuses_macos_library_disguised_as_ios(self):
        package(self.pkg, macho(platform=1))
        with self.assertRaisesRegex(ValueError, "not built for iOS"):
            self.prepare()

    def test_refuses_wrong_cpu_architecture(self):
        package(self.pkg, macho(arch=0x01000007))
        with self.assertRaisesRegex(ValueError, "ARM64"):
            self.prepare()

    def test_requires_real_embedded_license(self):
        package(self.pkg, macho(), b"no license included")
        with self.assertRaisesRegex(ValueError, "license"):
            self.prepare()

    def test_does_not_install_proprietary_executable_or_macos_binary(self):
        self.prepare()
        self.assertEqual({p.name for p in self.out.iterdir()},
                         {msc.LIBRARY_NAME, msc.LICENSE_NAME, msc.PROVENANCE_NAME})


if __name__ == "__main__":
    unittest.main()
