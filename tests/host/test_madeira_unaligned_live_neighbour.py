import unittest

from support import ROOT, repo_text


class MadeiraUnalignedLiveNeighbourTests(unittest.TestCase):
    def test_patch_emulates_instead_of_clobbering_a_live_slot(self):
        patch = (ROOT / "patches/madeira-unaligned-live-neighbour.patch").read_text()
        self.assertIn("+++ b/build/ntdll-unix/signal_arm64_ios.c", patch)
        self.assertIn("+                            if (nb != 0xD503201Fu /* nop */)", patch)
        self.assertIn("UNALIGNED-EMULATE", patch)
        self.assertIn("(int32_t)(insn << 11)) >> 23", patch)

    def test_patch_is_applied_and_invalidates_cached_kits(self):
        self.assertIn('UNALIGNED_PATCH="$ROOT/patches/madeira-unaligned-live-neighbour.patch"',
                      repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"patches/madeira-unaligned-live-neighbour.patch"', repo_text("scripts/madeira_native_kit.py"))


if __name__ == "__main__":
    unittest.main()
