import unittest

from support import ROOT, repo_text


class MadeiraArm64ImporterNativeBindTests(unittest.TestCase):
    def test_pure_arm64_importers_bind_to_native_targets(self):
        patch = (ROOT / "patches/madeira-arm64-importer-native-bind.patch").read_text()
        self.assertIn("+++ b/wine/dlls/ntdll/loader.c", patch)
        self.assertIn("imp_nt->FileHeader.Machine == IMAGE_FILE_MACHINE_ARM64", patch)
        self.assertEqual(patch.count("(imp_native_arm64 || !arm64ec_iat_is_exported_x64( module, thunk_list ))"), 2)

    def test_syscall_stubs_resolve_to_native_targets(self):
        patch = (ROOT / "patches/madeira-arm64-importer-syscall-bind.patch").read_text()
        self.assertIn("+++ b/wine/dlls/ntdll/signal_arm64ec.c", patch)
        self.assertIn("return xlate_ios_jit( arm64ec_syscalls[id] );", patch)
        self.assertIn("if (id < ideck_nb_syscalls && arm64ec_syscalls[id])", patch)
        self.assertIn('ARM64_SYSCALL_PATCH="$ROOT/patches/madeira-arm64-importer-syscall-bind.patch"',
                      repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"patches/madeira-arm64-importer-syscall-bind.patch"', repo_text("scripts/madeira_native_kit.py"))

    def test_lone_ret_exports_resolve_to_native_ret(self):
        patch = (ROOT / "patches/madeira-arm64-importer-ret-bind.patch").read_text()
        self.assertIn("+        if (bytes[0] == 0xc3)", patch)
        self.assertIn("+            return xlate_ios_jit( (void *)__chkstk_arm64ec );", patch)
        fetch = repo_text("scripts/fetch_madeira_sources.sh")
        self.assertIn('RET_BIND_PATCH="$ROOT/patches/madeira-arm64-importer-ret-bind.patch"', fetch)
        self.assertLess(fetch.index("madeira-arm64-importer-syscall-bind.patch"), fetch.index("RET_BIND_PATCH="))
        self.assertIn('"patches/madeira-arm64-importer-ret-bind.patch"', repo_text("scripts/madeira_native_kit.py"))

    def test_patch_is_applied_and_invalidates_cached_kits(self):
        self.assertIn('ARM64_IMPORTER_PATCH="$ROOT/patches/madeira-arm64-importer-native-bind.patch"',
                      repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"patches/madeira-arm64-importer-native-bind.patch"', repo_text("scripts/madeira_native_kit.py"))


if __name__ == "__main__":
    unittest.main()
