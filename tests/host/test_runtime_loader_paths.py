"""Exercise the loader path overlay, including existing patched checkouts."""
import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import ROOT

spec = importlib.util.spec_from_file_location("runtime_root", ROOT / "scripts/apply_madeira_runtime_root.py")
overlay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(overlay)


class RuntimeLoaderPathsTests(unittest.TestCase):
    def prepare(self, root, legacy=False):
        bridge = root / "app/Madeira/WineProcessBridge.m"
        bridge.parent.mkdir(parents=True)
        bridge.write_text(overlay.DATA_ENV)
        loader = root / "build/ntdll-unix/loader_ios.c"
        loader.parent.mkdir(parents=True)
        loader.write_text('''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
const char *dll_dir, *data_dir, *ntdll_dir;
void init_paths(const char *exe_path) {
    ntdll_dir = strdup( exe_path );
    dll_dir = strdup( exe_path );
    data_dir = strdup( exe_path );  /* NLS files at <bundle>/nls/ */
''' + (overlay.LEGACY_DATA_IOS if legacy else "") + '''}
#if 0
''' + overlay.FATAL_ANCHOR + '    pthread_exit( NULL );\n' + '''#endif
int main(int argc, char **argv) {
    char path[4096];
    init_paths(argv[1]);
    if (strcmp(ntdll_dir, argv[1])) return 1;
    if (strcmp(dll_dir, argv[2]) || strcmp(data_dir, argv[2])) return 2;
    snprintf(path, sizeof(path), "%s/arm64ec-windows/ntdll.dll", dll_dir);
    if (access(path, R_OK)) return 3;
    snprintf(path, sizeof(path), "%s/nls/l_intl.nls", data_dir);
    return access(path, R_OK) ? 4 : 0;
}
''')
        return loader

    def test_clean_and_legacy_checkouts_load_external_core_dll(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "C compiler required for loader regression")
        for legacy in (False, True):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                loader = self.prepare(root, legacy)
                self.assertEqual(overlay.data_dir(root), 0)
                first = loader.read_text()
                self.assertEqual(overlay.data_dir(root), 0)
                self.assertEqual(first, loader.read_text())
                self.assertEqual(first.count(overlay.FATAL_STDERR), 1)
                binary = root / "probe"
                subprocess.run([compiler, str(loader), "-o", str(binary)], check=True, capture_output=True)
                bundle = root / "iDeck.app"
                runtime = root / "Application Support/MadeiraRuntime"
                for directory in (bundle, runtime):
                    (directory / "arm64ec-windows").mkdir(parents=True)
                    (directory / "nls").mkdir()
                for name in ("arm64ec-windows/ntdll.dll", "nls/l_intl.nls"):
                    (runtime / name).write_bytes(b"runtime")
                import os
                env = dict(os.environ)
                env["MADEIRA_DATA_DIR"] = str(runtime)
                subprocess.run([str(binary), str(bundle), str(runtime)], env=env, check=True)
                # Development bundles still work without an external runtime.
                for name in ("arm64ec-windows/ntdll.dll", "nls/l_intl.nls"):
                    (bundle / name).write_bytes(b"bundled")
                for value in (None, "", "relative/path"):
                    env.pop("MADEIRA_DATA_DIR", None)
                    if value is not None:
                        env["MADEIRA_DATA_DIR"] = value
                    subprocess.run([str(binary), str(bundle), str(bundle)], env=env, check=True)

    def test_unknown_overlay_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            loader = self.prepare(root)
            original = loader.read_text() + '\n/* MADEIRA_DATA_DIR unexpected overlay */\n'
            loader.write_text(original)
            self.assertEqual(overlay.data_dir(root), 2)
            self.assertEqual(loader.read_text(), original)
