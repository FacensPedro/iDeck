"""NTMARTA.dll and CLBCATQ.dll: built as i386 PE into the WoW64 farm."""
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def exports(path: Path) -> dict:
    """Export name -> forward target (None for code) from a PE's export directory."""
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    sections = struct.unpack_from("<H", data, pe + 6)[0]
    optional = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    rva, size = struct.unpack_from("<II", data, opt + 96)
    table = [struct.unpack_from("<8sIIII", data, opt + optional + 40 * i)[1:5] for i in range(sections)]

    def offset(address):
        for vsize, vaddr, rawsize, raw in table:
            if vaddr <= address < vaddr + max(vsize, rawsize):
                return raw + address - vaddr
        raise ValueError(hex(address))

    def text(address):
        start = offset(address)
        return data[start:data.index(b"\0", start)].decode()

    base = offset(rva)
    count_functions, count_names, functions, names, ordinals = struct.unpack_from("<IIIII", data, base + 20)
    out = {}
    for i in range(count_names):
        name = text(struct.unpack_from("<I", data, offset(names) + 4 * i)[0])
        index = struct.unpack_from("<H", data, offset(ordinals) + 2 * i)[0]
        target = struct.unpack_from("<I", data, offset(functions) + 4 * index)[0]
        out[name] = text(target) if rva <= target < rva + size else None
    return out


@unittest.skipUnless(shutil.which("clang") and shutil.which("lld-link"), "needs clang and lld")
class CompatDLLBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.out = Path(cls.folder.name)
        subprocess.run(["bash", str(ROOT / "scripts/build_compat_dlls.sh"), str(cls.out), "clang"],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def test_both_are_i386(self):
        for name in ("ntmarta.dll", "clbcatq.dll"):
            data = (self.out / name).read_bytes()
            pe = struct.unpack_from("<I", data, 0x3C)[0]
            self.assertEqual(struct.unpack_from("<H", data, pe + 4)[0], 0x14C, name)

    def test_ntmarta_forwards_to_advapi32_without_decoration(self):
        table = exports(self.out / "ntmarta.dll")
        self.assertEqual(table["GetNamedSecurityInfoW"], "advapi32.GetNamedSecurityInfoW")
        self.assertEqual(len(table), 8)
        for name, target in table.items():
            self.assertEqual(target, "advapi32." + name)

    def test_clbcatq_exports_undecorated_com_entry_points(self):
        table = exports(self.out / "clbcatq.dll")
        self.assertEqual(sorted(table), ["DllCanUnloadNow", "DllGetClassObject", "DllRegisterServer", "DllUnregisterServer"])
        self.assertTrue(all(target is None for target in table.values()))


class CompatDLLWiringTests(unittest.TestCase):
    def test_forwarded_functions_exist_in_wines_advapi32(self):
        source = (ROOT / "build/compat-dlls/ntmarta.c").read_text()
        for name in ("GetNamedSecurityInfoW", "SetNamedSecurityInfoW", "TreeSetNamedSecurityInfoW"):
            self.assertIn(f"-export:{name}=advapi32.{name}", source)

    def test_built_after_the_i386_farm_and_keyed_in_the_kit_cache(self):
        components = (ROOT / "scripts/build_madeira_components.sh").read_text()
        self.assertLess(components.index('bash "$MD/build/wine-i386/build.sh"'),
                        components.index('bash "$ROOT/scripts/build_compat_dlls.sh" "$MD/app/Madeira/i386-windows"'))
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        kit = next(line for line in workflow.splitlines() if "key: madeira-kit-" in line)
        self.assertIn("'build/compat-dlls/*'", kit)


if __name__ == "__main__":
    unittest.main()
