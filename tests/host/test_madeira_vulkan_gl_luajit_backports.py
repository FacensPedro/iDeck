import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("madeira_luajit_patch", ROOT / "scripts/apply_madeira_luajit_backport.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MadeiraGraphicsAndLuaJITBackportTests(unittest.TestCase):
    def test_node24_workflows_have_no_node20_github_actions(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            source = path.read_text()
            self.assertNotIn("actions/checkout@v4", source, path.name)
            self.assertNotIn("actions/cache@v4", source, path.name)
            self.assertNotIn("actions/upload-artifact@v4", source, path.name)
            self.assertNotIn("actions/setup-node@v4", source, path.name)
        ios = (ROOT / ".github/workflows/ios.yml").read_text()
        self.assertIn("actions/setup-node@v5", ios)
        self.assertIn("node-version: '24'", ios)
        self.assertIn("actions/cache@v5", ios)

    def test_arm64ec_dcomp_build_has_exports_and_checks(self):
        c = (ROOT / "build/dcomp/dcomp.c").read_text()
        header = (ROOT / "build/dcomp/dcomp.def").read_text()
        shell = (ROOT / "scripts/build_madeira_dcomp.sh").read_text()
        build = (ROOT / "scripts/build_madeira_components.sh").read_text()
        for symbol in ("DCompositionCreateDevice", "DCompositionCreateDevice2", "DCompositionCreateDevice3"):
            self.assertIn(symbol, c)
            self.assertIn(symbol, header)
        self.assertIn("arm64ec-w64-mingw32-clang", shell)
        self.assertIn("llvm-readobj", shell)
        self.assertIn('head -c 2 "$OUTPUT"', shell)
        self.assertIn('bash "$ROOT/scripts/build_madeira_dcomp.sh"', build)

    def test_luajit_backport_replaces_only_known_wineserver_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            madeira = pathlib.Path(tmp)
            (madeira / "build/wineserver").mkdir(parents=True)
            mapping = madeira / "build/wineserver/mapping_ios.c"
            mapping.write_text(
                'static struct fd *mapping_get_fd( struct object *obj );\n'
                '        if (flags & SEC_IMAGE)\n'
                '        {\n'
                '            unsigned int err = get_image_params( mapping, st.st_size, unix_fd );\n'
                '            if (!err) return mapping;\n'
                '            set_error( err );\n'
                '            goto error;\n'
                '        }\n'
            )
            compiler = madeira / "build/wineserver/build.sh"
            compiler.write_text(
                'PATCHED_FILES=(\n'
                '    "mapping:$BUILD_DIR/mapping_ios.c:mapping.o"\n'
                ')\n'
                'REPLACEMENTS=(\n'
                '    "mapping.o:mapping.o"\n'
                ')\n'
            )
            MODULE.patch(madeira, ROOT)
            before = (mapping.read_text(), compiler.read_text())
            self.assertIn("madeira_luajit_compat_fd", before[0])
            self.assertIn("luajit_compat.o:luajit_compat.o", before[1])
            self.assertTrue((madeira / "build/wineserver/luajit_compat.c").is_file())
            MODULE.patch(madeira, ROOT)
            self.assertEqual(before, (mapping.read_text(), compiler.read_text()))

    def test_reject_unrecognized_wine_mapping_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            madeira = pathlib.Path(tmp)
            (madeira / "build/wineserver").mkdir(parents=True)
            (madeira / "build/wineserver/mapping_ios.c").write_text("unrecognized upstream ABI")
            (madeira / "build/wineserver/build.sh").write_text("PATCHED_FILES=()")
            with self.assertRaisesRegex(RuntimeError, "matching context"):
                MODULE.patch(madeira, ROOT)

    def test_luajit_gc64_build_and_verified_runtime_staging(self):
        build = (ROOT / "scripts/build_madeira_luajit.sh").read_text()
        stage = (ROOT / "scripts/stage_madeira_payload.sh").read_text()
        kit = (ROOT / "scripts/madeira_native_kit.py").read_text()
        fetch = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
        self.assertIn("a4c064539ea931274d407e1249b4bb575424a0f4", build)
        self.assertIn("LUAJIT_DISABLE_JIT", build)
        self.assertIn("LUAJIT_NO_UNWIND", build)
        self.assertIn("LuaJIT-MIT.txt", build)
        self.assertIn("compat/love/lua51.dll", stage)
        self.assertIn("LuaJIT-MIT.txt", stage)
        self.assertIn("compat/love/lua51.dll", kit)
        self.assertIn("luajit_backport_sha256", kit)
        self.assertIn("apply_madeira_luajit_backport.py", fetch)

    def test_vulkan_opengl_are_source_only_until_compiled_with_matching_wine(self):
        for relative in (
            "build/vulkan-ios/backend.c",
            "build/win32u-unix/vulkan_ios.c",
            "build/win32u-unix/vulkan_surface_ios.c",
            "build/win32u-unix/opengl_ios.c",
        ):
            source = ROOT / relative
            self.assertTrue(source.is_file(), relative)
            self.assertGreater(source.stat().st_size, 3000, relative)
        vulkan = (ROOT / "build/win32u-unix/vulkan_ios.c").read_text()
        self.assertIn("MADEIRA_VULKAN_LIBRARY", vulkan)
        self.assertIn("vulkan_surface_ios.c", vulkan)
        self.assertIn("madeira_vulkan_layer_acquire", (ROOT / "build/win32u-unix/vulkan_surface_ios.c").read_text())
        self.assertIn("MADEIRA_GL_BACKEND", (ROOT / "build/win32u-unix/opengl_ios.c").read_text())
        self.assertIn("madeira_vulkan_symbol", (ROOT / "build/vulkan-ios/backend.c").read_text())

    def test_toolchain_cache_restores_after_pinned_checkout_and_isolated_prs(self):
        ios = (ROOT / ".github/workflows/ios.yml").read_text()
        self.assertLess(ios.index("Fetch pinned Madeira with FEX, Wine and DXMT"), ios.index("Restore precompiled ARM64EC"))
        self.assertIn("vendor/Madeira/toolchains/llvm-ios-build", ios)
        self.assertIn("vendor/Madeira/toolchains/gnutls-ios", ios)
        self.assertIn("vendor/Madeira/toolchains/ffmpeg-ios", ios)
        self.assertIn("vars.IDECK_NATIVE_DISTRIBUTION_APPROVED == 'true'", ios)
        self.assertIn("github.event_name == 'push'", ios)


if __name__ == "__main__":
    unittest.main()
