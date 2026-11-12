import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches/madeira-iat-jit-sync-after-bind.patch").read_text()


class IatJitSyncTests(unittest.TestCase):
    def test_listed_in_native_group_after_alias_lifecycle(self):
        series = (ROOT / "patches/series.txt").read_text()
        self.assertLess(series.index("madeira-jit-alias-lifecycle.patch"),
                        series.index("native    .      madeira-iat-jit-sync-after-bind.patch"))

    def test_loader_syncs_the_bound_iat_before_dllmain(self):
        self.assertIn("+++ b/wine/dlls/ntdll/loader.c", PATCH)
        self.assertIn("IMAGE_DIRECTORY_ENTRY_IAT", PATCH)
        self.assertIn("unix_ios_sync_pe_write", PATCH)
        self.assertIn("#ifdef __arm64ec__", PATCH)

    def test_unix_side_accepts_bounded_iat_chunks(self):
        self.assertIn("+++ b/build/ntdll-unix/virtual_ios.c", PATCH)
        self.assertIn("p->size > 0x10000", PATCH)
        self.assertIn("(p->size & 7)", PATCH)


if __name__ == "__main__":
    unittest.main()
