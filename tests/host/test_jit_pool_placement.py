import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class JITPoolPlacementTests(unittest.TestCase):
    def test_native_address_policy(self):
        compiler = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(compiler, 'C compiler required for JIT policy regression')
        with tempfile.TemporaryDirectory() as temp:
            binary = str(pathlib.Path(temp) / 'placement')
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'tests/host/JITPoolPlacementTests.c'), '-o', binary], check=True)
            subprocess.run([binary], check=True)

    def test_early_reservation_with_mocked_mach_map(self):
        patch = (ROOT / 'patches/madeira-jit-early-hole.patch').read_text()
        first_hunk = patch.split('@@', 2)[2].split('\n@@', 1)[0]
        implementation = '\n'.join(line[1:] for line in first_hunk.splitlines() if line.startswith('+'))
        fixture = (ROOT / 'tests/host/JITEarlyReservationMock.c').read_text()
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp) / 'early.c'
            source.write_text(fixture.replace('/* INSERT_PATCH */', implementation))
            binary = str(pathlib.Path(temp) / 'early')
            subprocess.run([shutil.which('cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(source), '-o', binary], check=True)
            subprocess.run([binary], check=True)

    def test_failure_does_not_schedule_host_termination(self):
        helper = (ROOT / 'iDeck/MadeiraJIT/StikJITHelper.swift').read_text()
        self.assertNotIn('exit(0)', helper)
        self.assertNotIn('Killing in 10s', helper)
        self.assertIn('ideck_jit_pool_run(', helper)
        self.assertIn('ideck_jit_pool_placement_valid(', helper)
        allocate = helper.split('static func allocatePool(', 1)[1]
        self.assertLess(allocate.index('guard isDebuggerAttached()'), allocate.index('rwAliasHint()'))

if __name__ == '__main__':
    unittest.main()
