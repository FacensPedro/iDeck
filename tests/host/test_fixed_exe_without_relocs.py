import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "madeira-fixed-exe-without-relocs.patch").read_text()
SERIES = (ROOT / "patches" / "series.txt").read_text()


class FixedExeWithoutRelocsTests(unittest.TestCase):
    def test_listed_in_the_early_group(self):
        self.assertIn("early     .      madeira-fixed-exe-without-relocs.patch", SERIES)

    def test_only_the_wineserver_mapping_is_patched(self):
        self.assertEqual(PATCH.count("+++ b/"), 1)
        self.assertIn("+++ b/build/wineserver/mapping_ios.c", PATCH)

    def test_programs_without_relocations_stay_at_their_base(self):
        self.assertIn("+    if (!has_relocs && !(nt.FileHeader.Characteristics & IMAGE_FILE_DLL) &&", PATCH)
        self.assertIn("+        mapping->image.image_charact |= IMAGE_FILE_RELOCS_STRIPPED;", PATCH)
        self.assertIn("(mapping->image.contains_code && (nt.FileHeader.Characteristics & IMAGE_FILE_DLL))", PATCH)


if __name__ == "__main__":
    unittest.main()
