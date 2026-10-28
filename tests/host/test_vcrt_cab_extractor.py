import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest


EXTRACTOR = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
DLL_NAMES = (
    "concrt140.dll", "msvcp140.dll", "msvcp140_1.dll",
    "msvcp140_2.dll", "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll", "vcamp140.dll", "vccorlib140.dll",
    "vcomp140.dll", "vcruntime140.dll", "vcruntime140_1.dll",
    "vcruntime140_threads.dll", "mfc140.dll", "mfc140u.dll",
)


def pe_file(arch=0x8664, cert=True, identity=0):
    blob = bytearray(512)
    blob[0:2] = b"MZ"
    struct.pack_into("<I", blob, 0x3C, 0x80)
    blob[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", blob, 0x84, arch)
    struct.pack_into("<H", blob, 0x98, 0x20B)
    struct.pack_into("<I", blob, 0x98 + 108, 16)
    if cert:
        struct.pack_into("<II", blob, 0x98 + 112 + 32, 384, 16)
    blob[300] = identity
    return bytes(blob)


def make_cab(missing=None, machine=0x8664, cert=True):
    names = [x for x in DLL_NAMES if x != missing]
    files = [(f"F_CENTRAL_{name[:-4]}_amd64", pe_file(machine, cert, index + 1))
             for index, name in enumerate(DLL_NAMES) if name != missing]
    total = b"".join(data for _, data in files)
    folder_bytes = bytearray()
    cursor = 0
    for name, payload in files:
        folder_bytes += struct.pack("<IIHHHH", len(payload), cursor, 0, 0, 0, 0)
        folder_bytes += name.encode("ascii") + b"\0"
        cursor += len(payload)
    header_size = 36
    folder_size = 8
    file_offset = header_size + folder_size
    data_offset = file_offset + len(folder_bytes)
    data_block = struct.pack("<IHH", 0, len(total), len(total)) + total
    total_bytes = data_offset + len(data_block)
    header = struct.pack("<4sIIIII BBHHHHH", b"MSCF", 0, total_bytes, 0,
                         file_offset, 0, 3, 1, 1, len(files), 0, 1, 0)
    folder = struct.pack("<IHH", data_offset, 1, 0)
    return header + folder + folder_bytes + data_block


class ExtractorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def extract(self, cabinet):
        source = self.root / "Microsoft-VCRedist.exe"
        source.write_bytes(b"MZ" + bytes(510) + cabinet)
        target = self.root / "stage"
        target.mkdir()
        result = subprocess.run([str(EXTRACTOR), str(source), str(target)],
                                text=True, capture_output=True, check=False)
        return result, target

    def test_embedded_cab_extracts_every_signed_format_x64_dll(self):
        result, stage = self.extract(make_cab())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sorted(p.name for p in stage.iterdir()), sorted(DLL_NAMES))
        for i, name in enumerate(DLL_NAMES):
            self.assertEqual((stage / name).read_bytes()[300], i + 1, name)

    def test_missing_dll_fails_without_claiming_success(self):
        result, stage = self.extract(make_cab(missing="mfc140.dll"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mfc140.dll", result.stdout)

    def test_wrong_architecture_rejected(self):
        result, _ = self.extract(make_cab(machine=0x014C))
        self.assertNotEqual(result.returncode, 0)

    def test_unsigned_pe_rejected(self):
        result, _ = self.extract(make_cab(cert=False))
        self.assertNotEqual(result.returncode, 0)

    def test_malformed_cab_rejected(self):
        result, _ = self.extract(b"not a cabinet")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    sys.argv = [sys.argv[0]]
    unittest.main()
