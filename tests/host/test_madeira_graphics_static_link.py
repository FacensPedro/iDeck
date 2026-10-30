import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'iDeck' / 'NativeRuntime'


class MadeiraGraphicsStaticLinkTests(unittest.TestCase):
    def test_dxmt_uses_real_linked_present_counter(self):
        source = (NATIVE / 'DXMTBridge.mm').read_text(encoding='utf-8')
        self.assertIn('#include "MadeiraStaticABI.h"', source)
        self.assertIn('&madeira_get_present_count', source)
        self.assertIn('return false;', source)
        self.assertNotIn('dlsym(', source)

    def test_d3d12_uses_real_linked_canary(self):
        source = (NATIVE / 'D3D12Bridge.cpp').read_text(encoding='utf-8')
        self.assertIn('#include "MadeiraStaticABI.h"', source)
        self.assertIn('&madeira_d3d12_canary_run', source)
        self.assertIn('return false;', source)
        self.assertNotIn('dlsym(', source)

    def test_upstream_function_signatures_and_native_only_flag(self):
        header = (NATIVE / 'MadeiraStaticABI.h').read_text(encoding='utf-8')
        self.assertIn('uint64_t madeira_get_present_count(void);', header)
        self.assertIn(
            'int madeira_d3d12_canary_run(const char *fixture_dir, const char *dylib_path,',
            header,
        )
        self.assertIn('void (*sink)(const char *));', header)
        for name in ('DXMTBridge.mm', 'D3D12Bridge.cpp'):
            source = (NATIVE / name).read_text(encoding='utf-8')
            self.assertIn('defined(IDECK_NATIVE_MADEIRA_ENABLED)', source)


if __name__ == '__main__':
    unittest.main()
