import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def additions(name):
    return '\n'.join(line[1:] for line in (ROOT / 'patches' / name).read_text().splitlines()
                     if line.startswith('+') and not line.startswith('+++'))


class FEXMemoryFixesTests(unittest.TestCase):
    def run_c(self, source):
        cc = shutil.which('cc')
        if not cc:
            self.skipTest('C compiler unavailable')
        with tempfile.TemporaryDirectory() as directory:
            src = pathlib.Path(directory) / 'test.c'
            exe = pathlib.Path(directory) / 'test'
            src.write_text(source)
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_win32_success_failure_and_old_protection_output(self):
        # Compile the real changed wrapper tail, including its actual comparison.
        code = additions('fex-windows-protection-result.patch')
        tail = code[code.index('  DWORD old_prot'):code.index('\n  // The Windows')]
        tail = tail.split('#ifdef')[0].replace('DWORD old_prot {};', 'DWORD old_prot = 0;').replace('::VirtualProtect', 'mock_protect')
        self.run_c('''
#include <assert.h>
#include <stddef.h>
typedef unsigned long DWORD;
static int result, called;
static int mock_protect(void *ptr, size_t size, DWORD prot, DWORD *old) {
    assert(ptr == (void *)0x10000 && size == 4096 && prot == 1);
    assert(old); *old = 0x40; called++; return result;
}
static int wrapper(void *Ptr, size_t Size, DWORD prot) {
''' + tail + '''
}
int main(void) {
    result = 1; assert(wrapper((void *)0x10000, 4096, 1));
    result = 0; assert(!wrapper((void *)0x10000, 4096, 1));
    assert(called == 2);
}
''')

    def test_disjoint_layerkit_bands_do_not_exclude_the_gap(self):
        code = additions('madeira-layerkit-contiguous-range.patch')
        block = code[code.index('        if (n)'):code.index('        dprintf')]
        self.run_c('''
#include <assert.h>
#include <stdint.h>
typedef uint64_t mach_vm_address_t;
static uint64_t ios_layerkit_lo, ios_layerkit_hi;
static void select_band(uint64_t *got, unsigned n) {
    uint64_t lo = 0, hi = 0;
''' + block + '''
}
#define CHUNK (256ULL << 20)
int main(void) {
    uint64_t disjoint[] = {0x7700000000ULL, 0x140000000ULL, 0x130000000ULL};
    select_band(disjoint, 3);
    assert(ios_layerkit_lo == 0x130000000ULL && ios_layerkit_hi == 0x150000000ULL);
    ios_layerkit_lo = ios_layerkit_hi = 0;
    select_band(disjoint, 0); assert(!ios_layerkit_lo && !ios_layerkit_hi);
    uint64_t single[] = {0x7c00000000ULL};
    select_band(single, 1); assert(ios_layerkit_hi - ios_layerkit_lo == CHUNK);
    uint64_t later[] = {0x100000000ULL};
    select_band(later, 1); assert(ios_layerkit_lo == single[0]);
}
''')


if __name__ == '__main__':
    unittest.main()
