import sys
import unittest

from support import ROOT, repo_text


class MadeiraCoreStartupTests(unittest.TestCase):
    def test_relink_script_converts_multiline_and_keeps_lone_creates(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import apply_madeira_relink_cache as m
        src = (
            "        [fm removeItemAtPath:dst error:nil];  /* self-heal */\n"
            "        if ([fm createSymbolicLinkAtPath:dst\n"
            "                     withDestinationPath:[source stringByAppendingPathComponent:f] error:nil])\n"
            "            linked++;\n"
            "        [fm createSymbolicLinkAtPath:cLink withDestinationPath:other error:nil];\n"
        )
        out, n = m.convert(src)
        self.assertEqual(n, 1)
        self.assertIn("madeira_relink(fm, dst, [source stringByAppendingPathComponent:f])", out)
        self.assertNotIn("removeItemAtPath:dst", out)
        self.assertIn("[fm createSymbolicLinkAtPath:cLink withDestinationPath:other error:nil]", out)
        self.assertIn("if (!strcmp(cur, src.fileSystemRepresentation)) return YES;", m.HELPER)

    def test_fex_config_location_is_absolute_and_overridable(self):
        bridge = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
        self.assertIn('setenv("FEX_APP_CONFIG_LOCATION", "C:\\\\ProgramData\\\\fex-emu\\\\", 0);', bridge)
        self.assertIn('setenv("FEX_APP_DATA_LOCATION", "C:\\\\ProgramData\\\\fex-emu\\\\", 0);', bridge)

    def test_fusion_negative_cache(self):
        patch = (ROOT / "patches/madeira-mscoree-fusion-negative-cache.patch").read_text()
        self.assertIn("+    if (!pCreateAssemblyCache && fusion_missing) return fusion_missing;", patch)

    def test_wired_into_fetch_and_kit_hash(self):
        fetch = repo_text("scripts/fetch_madeira_sources.sh")
        kit = repo_text("scripts/madeira_native_kit.py")
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_relink_cache.py" "$DEST"', fetch)
        self.assertIn('FUSION_PATCH="$ROOT/patches/madeira-mscoree-fusion-negative-cache.patch"', fetch)
        self.assertIn('"scripts/apply_madeira_relink_cache.py"', kit)
        self.assertIn('"patches/madeira-mscoree-fusion-negative-cache.patch"', kit)


if __name__ == "__main__":
    unittest.main()
