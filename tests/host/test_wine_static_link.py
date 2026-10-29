import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'iDeck/NativeRuntime'


class WineStaticLinkTests(unittest.TestCase):
    def test_native_bridge_calls_linked_implementation_and_requires_it(self):
        compiler = shutil.which('c++')
        self.assertIsNotNone(compiler, 'C++ compiler required')
        source = (NATIVE / 'WineProcessBridge.mm').read_text()
        # Compile the real portable process ABI; only the trailing UI key-up
        # dispatch block requires Apple's Objective-C runtime.
        source = source.split('extern "C" bool ideck_wineprocess_request_close')[0]
        source = source.replace('#import', '#include').replace('#include <dispatch/dispatch.h>', '')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bridge.cpp').write_text(source)
            (root / 'main.cpp').write_text(r'''
#include "MadeiraRuntimeBridge.h"
#include "MadeiraStaticABI.h"
#include <cassert>
#include <cerrno>
#include <cstring>
static int started = 0;
extern "C" void *dlsym(void *, const char *) { return nullptr; }
extern "C" int wine_process_start(const char *p) { started = !strcmp(p, "/prefix"); return 0; }
extern "C" int wine_process_is_running() { return started; }
#ifndef OMIT_FINISHED
extern "C" int wine_process_thread_finished() { return !started; }
#endif
extern "C" int wine_process_exit_code() { return 42; }
extern "C" int wine_crash_exit_status(uint32_t *s) { *s = 0xc0000005; return 1; }
int main() {
    assert(ideck_wineprocess_start(nullptr) == EINVAL);
#ifdef IDECK_NATIVE_MADEIRA_ENABLED
    assert(ideck_wineprocess_thread_finished());
    assert(ideck_wineprocess_available());
    assert(ideck_wineprocess_start("/prefix") == 0);
    assert(ideck_wineprocess_running());
    assert(!ideck_wineprocess_thread_finished());
    int32_t code = 0;
    assert(ideck_wineprocess_last_exit_code(&code) && code == 42);
    uint32_t status = 0;
    assert(ideck_wineprocess_last_ntstatus(&status) && status == 0xc0000005);
#else
    assert(!ideck_wineprocess_available());
    assert(ideck_wineprocess_start("/prefix") == ENOSYS);
#endif
}
''')
            base = [compiler, '-std=c++17', '-I', str(NATIVE), str(root / 'bridge.cpp'),
                    str(root / 'main.cpp'), '-o', str(root / 'test')]
            for flags in ([], ['-DIDECK_NATIVE_MADEIRA_ENABLED=1']):
                with self.subTest(flags=flags):
                    subprocess.run(base + flags, check=True, capture_output=True, text=True)
                    subprocess.run([str(root / 'test')], check=True)
            missing = subprocess.run(base + ['-DIDECK_NATIVE_MADEIRA_ENABLED=1', '-DOMIT_FINISHED'],
                                     capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('wine_process_thread_finished', missing.stderr)


if __name__ == '__main__':
    unittest.main()
