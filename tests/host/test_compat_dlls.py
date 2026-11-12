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
        cls.spec = Path(cls.folder.name) / "vulkan-1.spec"
        cls.spec.write_text(
            "@ stdcall vkAcquireNextImageKHR(ptr int64 int64 int64 int64 ptr) winevulkan.vkAcquireNextImageKHR\n"
            "@ stdcall vkCmdSetBlendConstants(ptr ptr) winevulkan.vkCmdSetBlendConstants\n"
            "@ stdcall vkCmdSetDepthBias(ptr float float float) winevulkan.vkCmdSetDepthBias\n"
            "@ stdcall vkCreateInstance(ptr ptr ptr) winevulkan.vkCreateInstance\n"
            "@ stdcall vkEnumerateInstanceExtensionProperties(str ptr ptr) winevulkan.vkEnumerateInstanceExtensionProperties\n"
            "@ stdcall vkEnumerateInstanceLayerProperties(ptr ptr) winevulkan.vkEnumerateInstanceLayerProperties\n"
            "@ stdcall vkEnumerateInstanceVersion(ptr) winevulkan.vkEnumerateInstanceVersion\n"
            "@ stdcall vkGetDeviceProcAddr(ptr str) winevulkan.vkGetDeviceProcAddr\n"
            "@ stdcall vkGetInstanceProcAddr(ptr str) winevulkan.vkGetInstanceProcAddr\n")
        cls.out = Path(cls.folder.name) / "out"
        subprocess.run(["bash", str(ROOT / "scripts/build_compat_dlls.sh"), str(cls.out), "clang", str(cls.spec)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def test_both_are_i386(self):
        for name in ("ntmarta.dll", "clbcatq.dll", "vulkan-1.dll"):
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


    def test_vulkan1_exports_every_spec_name_undecorated(self):
        table = exports(self.out / "vulkan-1.dll")
        self.assertEqual(len(table), 9)
        self.assertIn("vkAcquireNextImageKHR", table)
        self.assertTrue(all(target is None for target in table.values()))

    def test_vulkan1_stdcall_sizes_follow_the_spec(self):
        generated = Path(self.folder.name) / "check.c"
        subprocess.run(["python3", str(ROOT / "build/compat-dlls/gen_vulkan1.py"), str(self.spec), str(generated)],
                       check=True, capture_output=True)
        source = generated.read_text()
        self.assertIn("-export:vkAcquireNextImageKHR=vkAcquireNextImageKHR@40", source)  # 4 + 4*8 + 4
        self.assertIn("-export:vkCmdSetDepthBias=vkCmdSetDepthBias@16", source)
        self.assertIn("-export:vkGetInstanceProcAddr=vkGetInstanceProcAddr@8", source)
        self.assertIn("return VK_ERROR_INCOMPATIBLE_DRIVER;", source)


class CompatDLLWiringTests(unittest.TestCase):
    def test_forwarded_functions_exist_in_wines_advapi32(self):
        source = (ROOT / "build/compat-dlls/ntmarta.c").read_text()
        for name in ("GetNamedSecurityInfoW", "SetNamedSecurityInfoW", "TreeSetNamedSecurityInfoW"):
            self.assertIn(f"-export:{name}=advapi32.{name}", source)

    def test_built_after_the_i386_farm_and_keyed_in_the_kit_cache(self):
        components = (ROOT / "scripts/build_madeira_components.sh").read_text()
        self.assertIn('"$MD/wine/dlls/vulkan-1/vulkan-1.spec"', components)
        self.assertLess(components.index('bash "$MD/build/wine-i386/build.sh"'),
                        components.index('bash "$ROOT/scripts/build_compat_dlls.sh" "$MD/app/Madeira/i386-windows"'))
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        kit = next(line for line in workflow.splitlines() if "key: madeira-kit-" in line)
        self.assertIn("'build/compat-dlls/*'", kit)


if __name__ == "__main__":
    unittest.main()
