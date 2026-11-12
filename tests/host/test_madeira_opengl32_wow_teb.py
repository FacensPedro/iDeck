import unittest

from support import ROOT, repo_text, patch_group


class MadeiraOpengl32WowTebTests(unittest.TestCase):
    def test_get_teb64_resolves_guest_teb_in_window(self):
        patch = (ROOT / "patches/madeira-opengl32-wow-teb.patch").read_text()
        self.assertIn("+++ b/wine/dlls/opengl32/unix_private.h", patch)
        self.assertIn("if (PtrToUlong( cur32 ) == teb32) return cur;", patch)
        self.assertIn("& ~(ULONG_PTR)0xffffffff) | teb32", patch)

    def test_patch_is_applied_and_invalidates_cached_kits(self):
        self.assertEqual(patch_group("madeira-opengl32-wow-teb.patch"), "native")
        self.assertIn('"patches/madeira-opengl32-wow-teb.patch"', repo_text("scripts/madeira_native_kit.py"))


if __name__ == "__main__":
    unittest.main()
