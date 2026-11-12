import unittest

from support import ROOT, repo_text, patch_group


class MadeiraArm64CpuAreaTests(unittest.TestCase):
    def test_patch_gives_arm64_processes_in_arm64ec_sessions_a_cpu_area(self):
        patch = (ROOT / "patches/madeira-arm64-cpu-area.patch").read_text()
        self.assertIn("+++ b/build/ntdll-unix/thread_ios.c", patch)
        self.assertIn("+         (ios_ii->Machine == IMAGE_FILE_MACHINE_ARM64 && is_arm64ec())))", patch)

    def test_patch_gives_wow64_children_a_cpu_area(self):
        patch = (ROOT / "patches/madeira-arm64-cpu-area.patch").read_text()
        self.assertIn("+        if (is_arm64ec() && !teb->ChpeV2CpuAreaInfo)", patch)
        self.assertIn('ios_its_step = "WoW64 emulator area";', patch)

    def test_patch_is_applied_and_invalidates_cached_kits(self):
        self.assertEqual(patch_group("madeira-arm64-cpu-area.patch"), "early")
        self.assertIn('"patches/madeira-arm64-cpu-area.patch"', repo_text("scripts/madeira_native_kit.py"))


if __name__ == "__main__":
    unittest.main()
