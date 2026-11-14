"""Stand-ins for the Direct3D companion DLLs Wine has no implementation of."""
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPORTS = {
    "d3d11on12.dll": ["D3D11On12CreateDevice"],
    "d3d9on12.dll": ["Direct3DCreate9On12", "Direct3DCreate9On12Ex"],
    "d3dcsx_42.dll": ["D3DX11CreateFFT", "D3DX11CreateFFT1DComplex", "D3DX11CreateFFT1DReal", "D3DX11CreateFFT2DComplex",
                      "D3DX11CreateFFT2DReal", "D3DX11CreateFFT3DComplex", "D3DX11CreateFFT3DReal", "D3DX11CreateScan",
                      "D3DX11CreateSegmentedScan"],
}
EXPORTS["d3dcsx_43.dll"] = EXPORTS["d3dcsx_42.dll"]


def pe_facts(path: Path):
    """Machine type, whether the image imports anything, and its export names."""
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional = pe + 24
    directories = optional + (96 if struct.unpack_from("<H", data, optional)[0] == 0x10B else 112)
    export_rva, _, import_rva = struct.unpack_from("<III", data, directories)
    table = optional + struct.unpack_from("<H", data, pe + 20)[0]
    sections = [struct.unpack_from("<IIII", data, table + 40 * index + 8) for index in range(count)]

    def offset(rva):
        for size, address, raw_size, raw in sections:
            if address <= rva < address + max(size, raw_size):
                return rva - address + raw
        raise ValueError(rva)

    directory = offset(export_rva)
    names = offset(struct.unpack_from("<I", data, directory + 32)[0])
    found = []
    for index in range(struct.unpack_from("<I", data, directory + 24)[0]):
        start = offset(struct.unpack_from("<I", data, names + 4 * index)[0])
        found.append(data[start:data.index(b"\0", start)].decode())
    return machine, import_rva != 0, found


class WiringTests(unittest.TestCase):
    def test_built_into_both_farms_and_in_the_cache_key(self):
        components = (ROOT / "scripts/build_madeira_components.sh").read_text()
        self.assertIn('bash "$ROOT/scripts/build_d3d_stub_dlls.sh" "$MD/app/Madeira/arm64ec-windows" x86_64', components)
        self.assertIn('bash "$ROOT/scripts/build_d3d_stub_dlls.sh" "$MD/app/Madeira/i386-windows" i386', components)
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        self.assertIn("'scripts/build_d3d_stub_dlls.sh', 'build/d3d-stubs/*'", workflow)

    def test_dxtrans_joins_the_x64_farm(self):
        self.assertIn("dlls/dxtrans/arm64ec-windows/dxtrans.dll", (ROOT / "scripts/arm64ec_extra_modules.txt").read_text())


@unittest.skipUnless(shutil.which("clang") and shutil.which("ld.lld"), "needs clang and lld")
class BuildTests(unittest.TestCase):
    def test_each_architecture_exports_plain_names_and_imports_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            for arch, machine in (("i386", 0x14C), ("x86_64", 0x8664)):
                out = Path(folder) / arch
                subprocess.run(["bash", str(ROOT / "scripts/build_d3d_stub_dlls.sh"), str(out), arch, "clang"],
                               check=True, capture_output=True)
                for name, exports in EXPORTS.items():
                    found_machine, imports, found = pe_facts(out / name)
                    self.assertEqual(found_machine, machine, name)
                    self.assertFalse(imports, name)
                    self.assertEqual(found, exports, f"{arch} {name}")


if __name__ == "__main__":
    unittest.main()
