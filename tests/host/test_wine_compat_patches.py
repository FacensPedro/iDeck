"""Vendored Wine Staging and GE-Proton patches: Windows-side DLL code only."""
import importlib.util
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / "patches/wine-compat"
FORBIDDEN = re.compile(
    r"^(server/|dlls/ntdll/|dlls/kernelbase/|dlls/win32u/|dlls/wined3d/|dlls/winevulkan/|loader/|tools/|"
    r"configure|libs/vkd3d/|include/wine/server|dlls/winex11|dlls/winemac|dlls/winewayland|dlls/winepulse|"
    r"dlls/wineps|dlls/winegstreamer|programs/cmd/)")


def module():
    spec = importlib.util.spec_from_file_location("wine_compat", ROOT / "scripts/apply_madeira_wine_compat.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class SelectionTests(unittest.TestCase):
    def test_no_patch_touches_the_parts_madeira_ports(self):
        patches = list(PATCHES.rglob("*.patch"))
        self.assertGreater(len(patches), 50)
        for patch in patches:
            for line in patch.read_text(errors="replace").splitlines():
                if line.startswith("+++ b/"):
                    path = line[6:].strip()
                    self.assertIsNone(FORBIDDEN.match(path), f"{patch.name}: {path}")
                    self.assertFalse(path.endswith(("Makefile.in", ".spec")), f"{patch.name}: {path}")

    def test_sources_lists_every_set_and_pin(self):
        sources = (PATCHES / "SOURCES.md").read_text()
        for folder in (PATCHES / "staging").iterdir():
            self.assertIn(f"`{folder.name}`", sources)
        for patch in (PATCHES / "ge-proton").glob("*.patch"):
            self.assertIn(f"`{patch.name}`", sources)
        self.assertIn("f17c9eab35d6557a4533b6df141f424383530ad4", sources)
        self.assertIn("2b270a204beb7379efd8357462d3baa301e9dacd", sources)

    def test_fetch_applies_them_and_the_kit_key_covers_them(self):
        fetch = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_wine_compat.py" "$DEST"', fetch)
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        kit = next(line for line in workflow.splitlines() if "key: madeira-kit-" in line)
        self.assertIn("'patches/**'", kit)


class ApplyTests(unittest.TestCase):
    def tree(self, folder: str) -> Path:
        wine = Path(folder) / "wine"
        (wine / "dlls/ntdll").mkdir(parents=True)
        (wine / "dlls/demo").mkdir()
        (wine / "dlls/demo/main.c").write_text("one\ntwo\nthree\n")
        subprocess.run(["git", "-C", str(wine), "init", "-q"], check=True)
        return wine

    def series(self, folder: str, loaded) -> None:
        patches = Path(folder) / "patches"
        (patches / "staging/demo").mkdir(parents=True)
        (patches / "ge-proton").mkdir()
        (patches / "staging/demo/0001-first.patch").write_text(
            "--- a/dlls/demo/main.c\n+++ b/dlls/demo/main.c\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n")
        (patches / "staging/demo/0002-second.patch").write_text(
            "--- a/dlls/demo/main.c\n+++ b/dlls/demo/main.c\n@@ -1,3 +1,3 @@\n one\n-TWO\n+2\n three\n")
        loaded.PATCHES = patches

    def test_a_series_is_applied_once_in_order(self):
        loaded = module()
        with tempfile.TemporaryDirectory() as folder:
            wine = self.tree(folder)
            self.series(folder, loaded)
            self.assertEqual(loaded.main(folder), 0)
            self.assertEqual((wine / "dlls/demo/main.c").read_text(), "one\n2\nthree\n")
            self.assertEqual(loaded.main(folder), 0)  # marker: nothing applied twice
            self.assertEqual((wine / "dlls/demo/main.c").read_text(), "one\n2\nthree\n")

    def test_a_conflict_or_another_series_stops_the_build(self):
        loaded = module()
        with tempfile.TemporaryDirectory() as folder:
            wine = self.tree(folder)
            self.series(folder, loaded)
            (wine / "dlls/demo/main.c").write_text("changed upstream\n")
            self.assertEqual(loaded.main(folder), 2)
        with tempfile.TemporaryDirectory() as folder:
            wine = self.tree(folder)
            self.series(folder, loaded)
            (wine / loaded.MARKER).write_text("another\n")
            self.assertEqual(loaded.main(folder), 2)


if __name__ == "__main__":
    unittest.main()
