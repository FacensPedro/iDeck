import pathlib, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
P = ROOT / "patches"

class EcBindAndAliasTable(unittest.TestCase):
    def test_series_order(self):
        s = (P / "series.txt").read_text()
        self.assertLess(s.index("madeira-iat-jit-sync-after-bind.patch"), s.index("madeira-ec-bind-slot-sync.patch"))
        self.assertIn("native    FEX    fex-ios-alias-table-1024.patch", s)

    def test_slot_synced_at_redirect(self):
        t = (P / "madeira-ec-bind-slot-sync.patch").read_text()
        self.assertIn("+                    WINE_UNIX_CALL( unix_ios_sync_pe_write, &sync );", t)
        self.assertIn("sizeof(ULONG_PTR)", t)

    def test_alias_table_grown(self):
        t = (P / "fex-ios-alias-table-1024.patch").read_text()
        self.assertIn("-constexpr int kMaxEntries = 256;", t)
        self.assertIn("+constexpr int kMaxEntries = 1024;", t)

if __name__ == "__main__":
    unittest.main()
