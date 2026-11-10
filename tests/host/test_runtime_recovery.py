import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import ROOT


class RuntimeRecoveryTests(unittest.TestCase):
    def test_fatal_loader_returns_to_owner_cleanup(self):
        spec = importlib.util.spec_from_file_location('overlay', ROOT / 'scripts/apply_madeira_runtime_root.py')
        overlay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(overlay)
        code = r'''
#include <assert.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
static jmp_buf owner;
static int running = 1, finished = 0, server = 1, exit_code;
static void wine_ios_exit(int status) { exit_code = status; longjmp(owner, 1); }
#define exit(status) wine_ios_exit(status)
static void fatal_error(void) {
''' + overlay.FATAL_EXIT + r'''}
int main(void) {
    if (!setjmp(owner)) { fatal_error(); assert(0); }
    running = 0; server = 0; finished = 1;
    assert(exit_code == 1 && !running && !server && finished);
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'fatal.c'
            source.write_text(code)
            binary = Path(tmp) / 'fatal'
            subprocess.run(['cc', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required (runs on macOS CI)')
    def test_compiled_runtime_repair_rollback_and_resume(self):
        source = (ROOT / 'iDeck/MadeiraRuntime.swift').read_text().replace('import CryptoKit', '')
        start = source.index('    static var root: URL {')
        end = source.index('\n    }', start) + len('\n    }')
        source = source[:start] + '    static var root: URL = URL(fileURLWithPath: "/unused")' + source[end:]
        start = source.index('    static let packages: [Package] = {')
        end = source.index('    }()', start) + len('    }()')
        source = source[:start] + '    static var packages: [Package] = []' + source[end:]
        harness = (ROOT / 'tests/host/RuntimeRecoveryTests.swift').read_text()
        with tempfile.TemporaryDirectory() as tmp:
            swift = Path(tmp) / 'Runtime.swift'
            swift.write_text(source + '\n' + harness)
            binary = Path(tmp) / 'runtime-tests'
            subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
