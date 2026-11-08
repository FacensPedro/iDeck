import unittest

from support import ROOT, repo_text


class MadeiraArm64ImporterNativeBindTests(unittest.TestCase):
    def test_pure_arm64_importers_bind_to_native_targets(self):
        patch = (ROOT / "patches/madeira-arm64-importer-native-bind.patch").read_text()
        self.assertIn("+++ b/wine/dlls/ntdll/loader.c", patch)
        self.assertIn("imp_nt->FileHeader.Machine == IMAGE_FILE_MACHINE_ARM64", patch)
        self.assertEqual(patch.count("(imp_native_arm64 || !arm64ec_iat_is_exported_x64( module, thunk_list ))"), 2)

    def test_patch_is_applied_and_invalidates_cached_kits(self):
        self.assertIn('ARM64_IMPORTER_PATCH="$ROOT/patches/madeira-arm64-importer-native-bind.patch"',
                      repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"patches/madeira-arm64-importer-native-bind.patch"', repo_text("scripts/madeira_native_kit.py"))


if __name__ == "__main__":
    unittest.main()
