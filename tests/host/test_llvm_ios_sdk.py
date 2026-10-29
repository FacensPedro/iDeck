import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('sdk', ROOT / 'scripts/llvm_ios_sdk.py')
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class LLVMCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.build = self.root / 'build'
        self.ref = 'llvmorg-15.0.7'
        for header in sdk.HEADERS:
            self.write(self.source / 'include' / header, 'source header')
        for header in sdk.GENERATED:
            self.write(self.build / 'include' / header, 'generated header')
        for archive in sdk.ARCHIVES:
            self.write(self.build / 'lib' / f'lib{archive}.a', '!<arch>\n')
        self.write(self.source / 'include/llvm/ADT/ExtraDependency.h', 'transitive header')

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def test_old_cache_rejected_then_repaired_and_relocatable(self):
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            sdk.validate(self.build, self.ref)
        sdk.stage(self.source, self.build, self.ref)
        import shutil
        shutil.rmtree(self.source)
        moved = self.root / 'restored'
        self.build.rename(moved)
        sdk.validate(moved, self.ref)
        self.assertEqual((moved / 'include/llvm/ADT/ExtraDependency.h').read_text(), 'transitive header')
        for header in sdk.GENERATED:
            self.assertEqual((moved / 'include' / header).read_text(), 'generated header')

    def test_partial_cache_not_stamped(self):
        (self.build / 'lib/libLLVMBitReader.a').unlink()
        with self.assertRaisesRegex(ValueError, 'libLLVMBitReader'):
            sdk.stage(self.source, self.build, self.ref)
        self.assertFalse((self.build / sdk.MARKER).exists())

    def test_revision_mismatch_and_missing_generated_header(self):
        sdk.stage(self.source, self.build, self.ref)
        with self.assertRaisesRegex(ValueError, 'revision mismatch'):
            sdk.validate(self.build, 'llvmorg-16.0.0')
        (self.build / 'include/llvm/IR/Intrinsics.inc').unlink()
        with self.assertRaisesRegex(ValueError, 'Intrinsics.inc'):
            sdk.validate(self.build, self.ref)

    def test_source_missing_cannot_claim_valid_sdk(self):
        (self.source / 'include' / sdk.HEADERS[0]).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing LLVM source'):
            sdk.stage(self.source, self.build, self.ref)
        self.assertFalse((self.build / sdk.MARKER).exists())


if __name__ == '__main__':
    unittest.main()
