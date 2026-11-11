"""Windows runtime contents: every NLS table, no test programs, no redundant installers."""
import importlib.util
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def text(path: str) -> str:
    return (ROOT / path).read_text()


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FullNLSTests(unittest.TestCase):
    def tree(self, root: Path):
        (root / "wine/nls").mkdir(parents=True)
        (root / "app/Madeira/nls").mkdir(parents=True)
        for name in ("locale", "c_1252", "c_437", "c_850", "c_932", "c_1251", "c_10000", "c_866"):
            (root / "wine/nls" / f"{name}.nls").write_bytes(b"wine-" + name.encode())
        for name in ("locale", "c_1252", "c_437"):
            (root / "app/Madeira/nls" / f"{name}.nls").write_bytes(b"madeira-" + name.encode())

    def test_missing_tables_are_added_and_madeiras_kept(self):
        module = load("apply_madeira_full_nls")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.tree(root)
            self.assertEqual(module.main(str(root)), 0)
            nls = root / "app/Madeira/nls"
            self.assertEqual((nls / "c_850.nls").read_bytes(), b"wine-c_850")
            self.assertEqual((nls / "c_1252.nls").read_bytes(), b"madeira-c_1252")
            self.assertEqual(len(list(nls.glob("*.nls"))), 8)
            self.assertEqual(module.main(str(root)), 0)  # idempotent

    def test_a_tree_without_the_required_tables_fails(self):
        module = load("apply_madeira_full_nls")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.tree(root)
            (root / "wine/nls/c_850.nls").unlink()
            self.assertEqual(module.main(str(root)), 2)

    def test_fetch_kit_and_staging_require_the_full_set(self):
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_full_nls.py" "$DEST"', text("scripts/fetch_madeira_sources.sh"))
        kit = load("madeira_native_kit")
        for name in ("nls/c_850.nls", "nls/c_932.nls", "nls/c_1251.nls", "nls/c_10000.nls"):
            self.assertIn(name, kit.FULL_NLS_FILES)
        self.assertIn("+ FULL_NLS_FILES +", text("scripts/madeira_native_kit.py"))
        self.assertIn("for table in c_850.nls c_932.nls c_1251.nls c_10000.nls; do", text("scripts/stage_madeira_payload.sh"))


class SplitRuntimeTests(unittest.TestCase):
    def test_test_programs_are_left_out_and_real_files_kept(self):
        with tempfile.TemporaryDirectory() as folder:
            app, out = Path(folder) / "iDeck.app", Path(folder) / "out"
            for name in ("arm64ec-windows/ntdll.dll", "arm64ec-windows/cmd.exe", "arm64ec-windows/hello-x64.exe",
                         "arm64ec-windows/tftrace-x64.dll", "aarch64-windows/wineboot.exe",
                         "aarch64-windows/triangle.exe", "i386-windows/ntdll.dll", "nls/c_850.nls"):
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"MZ" + name.encode())
            subprocess.run([sys.executable, str(ROOT / "scripts/split_runtime_downloads.py"),
                            "--app", str(app), "--out", str(out)], check=True, capture_output=True)
            archive = next(out.glob("wine-x64-*.tar.xz"))
            with tarfile.open(archive) as tar:
                names = set(tar.getnames())
                manifest = json.load(tar.extractfile("ideck-runtime-wine-x64.json"))
            self.assertNotIn("arm64ec-windows/hello-x64.exe", names)
            self.assertNotIn("aarch64-windows/triangle.exe", names)
            self.assertNotIn("arm64ec-windows/hello-x64.exe", manifest)
            for kept in ("arm64ec-windows/cmd.exe", "arm64ec-windows/tftrace-x64.dll",
                         "aarch64-windows/wineboot.exe", "nls/c_850.nls"):
                self.assertIn(kept, names)
                self.assertIn(kept, manifest)


class ArchitectureGateTests(unittest.TestCase):
    @staticmethod
    def image(machine: int) -> bytes:
        return b"MZ" + bytes(0x3A) + (0x40).to_bytes(4, "little") + b"PE\0\0" + machine.to_bytes(2, "little") + bytes(32)

    def split(self, extra):
        with tempfile.TemporaryDirectory() as folder:
            app, out = Path(folder) / "iDeck.app", Path(folder) / "out"
            files = {"arm64ec-windows/ntdll.dll": 0x8664, "aarch64-windows/wineboot.exe": 0xAA64,
                     "i386-windows/ntdll.dll": 0x014C}
            files.update(extra)
            for name, machine in files.items():
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(self.image(machine))
            (app / "arm64ec-windows/dock-notices.txt").write_text("notice")
            return subprocess.run([sys.executable, str(ROOT / "scripts/split_runtime_downloads.py"),
                                   "--app", str(app), "--out", str(out)], capture_output=True, text=True)

    def test_matching_farms_are_packaged(self):
        self.assertEqual(self.split({}).returncode, 0)

    def test_an_x86_dll_in_the_x64_farm_stops_the_build(self):
        result = self.split({"arm64ec-windows/d3d9.dll": 0x014C})
        self.assertEqual(result.returncode, 2)
        self.assertIn("arm64ec-windows/d3d9.dll (machine 0x014c)", result.stderr)

    def test_an_x64_dll_in_the_x86_farm_stops_the_build(self):
        result = self.split({"i386-windows/msvcp140.dll": 0x8664})
        self.assertEqual(result.returncode, 2)
        self.assertIn("i386-windows/msvcp140.dll", result.stderr)


class GOGRedistributableTests(unittest.TestCase):
    def test_visual_cpp_2005_to_2013_installers_are_not_run(self):
        setup = text("iDeck/GOGSetup.swift")
        self.assertIn("static func visualCppLegacy(_ id: String) -> Bool", setup)
        self.assertIn('["msvc2005", "msvc2008", "msvc2010", "msvc2012", "msvc2013"]', setup)
        self.assertIn("Not needed: iDeck installs Visual C++ 2005-2013 on demand", setup)
        plan = setup[setup.index("static func plan("):setup.index("static func isHash")]
        self.assertLess(plan.index("visualCppLegacy(d.id)"), plan.index("d.isProgram"))

    def test_installers_recorded_by_an_older_install_are_filtered(self):
        setup = text("iDeck/GOGSetup.swift")
        batch = setup[setup.index("static func batchLines("):]
        self.assertIn("!providedByiDeck($0.id)", batch)


if __name__ == "__main__":
    unittest.main()
