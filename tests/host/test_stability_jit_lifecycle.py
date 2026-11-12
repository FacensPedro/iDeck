import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from support import ROOT, repo_text, patch_group


class StabilityJITLifecycleTests(unittest.TestCase):
    def test_getprocaddress_and_delay_load_native_for_pure_arm64(self):
        patch = (ROOT / "patches/madeira-arm64-getprocaddress-native.patch").read_text()
        self.assertIn("+static BOOL is_native_arm64_module( HMODULE module )", patch)
        self.assertIn("+        if (arm64ec_get_module_metadata( base ) || is_native_arm64_module( base ))", patch)
        self.assertIn("xlate_ios_jit_rev( __builtin_return_address( 0 ) )", patch)

    def test_unloaded_image_retires_its_anon_aliases_and_watchdog_is_safe(self):
        patch = (ROOT / "patches/madeira-jit-alias-lifecycle.patch").read_text()
        self.assertIn("+    if (view->protect & SEC_IMAGE) ios_jit_purge_image_aliases( view->base, view->size );", patch)
        self.assertIn("thread already exited (kr=%d): no sample", patch)
        self.assertIn("-                int kill_ret = pthread_kill(wine_pthread, 0);", patch)

    def test_patches_and_script_are_applied_and_hashed(self):
        fetch = repo_text("scripts/fetch_madeira_sources.sh")
        kit = repo_text("scripts/madeira_native_kit.py")
        for name in ("madeira-arm64-getprocaddress-native.patch", "madeira-jit-alias-lifecycle.patch"):
            self.assertEqual(patch_group(name), "native")
            self.assertIn(f'"patches/{name}"', kit)
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_opengl32_wow_ptrs.py" "$DEST"', fetch)
        self.assertIn('"scripts/apply_madeira_opengl32_wow_ptrs.py"', kit)

    def test_opengl32_script_keeps_integers_and_handles(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import apply_madeira_opengl32_wow_ptrs as m
        src = ("f( ULongToPtr(params->pixels), (GLintptr)ULongToPtr(params->offset), "
               "ULongToPtr(params->hdc), *(PTR32 *)UlongToPtr(params->params) );")
        out, n = m.convert(src)
        self.assertEqual(n, 2)
        self.assertIn("IOS_WOW_GUEST_PTR(params->pixels)", out)
        self.assertIn("(GLintptr)ULongToPtr(params->offset)", out)
        self.assertIn("ULongToPtr(params->hdc)", out)
        self.assertIn("*(PTR32 *)IOS_WOW_GUEST_PTR(params->params)", out)

    def test_session_cleanup_is_awaited_and_pool_defaults_to_560(self):
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertIn("private func waitForSessionCleanup(timeout: TimeInterval = 5) -> Bool", coordinator)
        self.assertIn('"wineJITPool560Migrated"', coordinator)
        self.assertIn("return (256...1152).contains(chosen) ? chosen : 560", repo_text("iDeck/MadeiraJIT/MadeiraWinePool.swift"))
        jit = repo_text("iDeck/MadeiraJIT/StikJITHelper.swift")
        self.assertIn("static var poolCountsAgainstFootprint = false", jit)
        self.assertNotIn('LogStore.shared.log("[no-footprint] pool applied=\\(exempt)"', jit)


if __name__ == "__main__":
    unittest.main()
