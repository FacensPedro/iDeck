import pathlib, unittest
S = (pathlib.Path(__file__).resolve().parents[2] / "scripts/fetch_madeira_sources.sh").read_text()

class FetchClearsPatchRecords(unittest.TestCase):
    def test_records_dropped_after_forced_checkout(self):
        drop = S.index('-name ideck-applied-patches -type f -delete')
        self.assertLess(S.index('checkout -f --detach "$REV"'), drop)
        self.assertLess(drop, S.index('apply_madeira_patches.py" "$DEST" early'))

if __name__ == "__main__":
    unittest.main()
