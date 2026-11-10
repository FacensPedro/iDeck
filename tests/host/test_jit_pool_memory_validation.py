import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from support import ROOT, repo_text


class JITPoolMemoryValidationTests(unittest.TestCase):
    def test_actual_native_pool_checks_with_mocked_mach_regions(self):
        source = repo_text('iDeck/NativeRuntime/FEXRuntime.cpp')
        for header in ('sys/sysctl.h', 'mach/mach.h', 'mach/mach_vm.h'):
            source = source.replace('#include <' + header + '>', '')
        fixture = repo_text('tests/host/JITPoolMemoryValidationTests.cpp')
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'pool.cpp'
            file.write_text(fixture.replace('/* ACTUAL_FEX_RUNTIME */', source))
            binary = Path(tmp) / 'pool'
            subprocess.run(['c++', '-std=c++17', '-pthread', '-I', str(ROOT / 'iDeck/NativeRuntime'),
                            str(file), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required (macOS CI)')
    def test_actual_swift_cleanup_and_readiness(self):
        source = repo_text('iDeck/MadeiraJIT/StikJITHelper.swift')
        start = source.index('    static func discardPool(')
        end = source.index('\n    /// Default requests', start)
        cleanup = source[start:end]
        start = source.index('        var retainPrimaryRX = false')
        end = source.index('        let rxAddr = Int(bitPattern: rxPtr)', start)
        deferred = source[start:end]
        start = source.index('    static var ready: Bool {')
        end = source.index('\n    }', start) + len('\n    }')
        ready = source[start:end]
        fixture = repo_text('tests/host/JITPoolCleanupTests.swift')
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'cleanup.swift'
            file.write_text(fixture.replace('/* ACTUAL_DISCARD */', cleanup)
                           .replace('/* ACTUAL_DEFER */', deferred).replace('/* ACTUAL_READY */', ready))
            binary = Path(tmp) / 'cleanup'
            subprocess.run(['swiftc', '-parse-as-library', str(file), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
