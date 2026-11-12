import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class Wow64winAtomTests(unittest.TestCase):
    def test_patch_listed_and_passes_atoms(self):
        self.assertIn("wine      wine   wine-wow64win-atoms.patch", (ROOT / "patches/series.txt").read_text())
        patch = (ROOT / "patches/wine-wow64win-atoms.patch").read_text()
        self.assertIn("+++ b/dlls/wow64win/wow64win_private.h", patch)
        self.assertIn("+    if (!(addr >> 16)) return (void *)(ULONG_PTR)addr;", patch)
        self.assertIn("+    if (!((ULONG_PTR)addr >> 16)) return (ULONG)(ULONG_PTR)addr;", patch)

    def test_arm64_wow64win_is_built_from_the_patched_tree(self):
        components = (ROOT / "scripts/build_madeira_components.sh").read_text()
        self.assertIn("dlls/wow64win/aarch64-windows/wow64win.dll", components)
        self.assertIn('-o "$MD/app/Madeira/aarch64-windows/wow64win.dll" "$WOW64WIN"', components)


if __name__ == "__main__":
    unittest.main()
