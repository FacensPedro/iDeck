import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FEX = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")

class AutomaticWineJITPoolTests(unittest.TestCase):
    def test_supported_sizes_and_manual_override(self):
        self.assertIn('getenv("IDECK_WINE_JIT_MIB")', FEX)
        self.assertIn('sysctlbyname("hw.memsize"', FEX)
        self.assertIn('constexpr size_t allowed[] = {1152, 896, 768, 640, 512, 384, 256, 192, 128, 96, 64}', FEX)
        self.assertIn('errno == 0 && end != override_text && *end ==', FEX)
        self.assertIn('if (value == candidate)', FEX)
        self.assertIn("*end == '\\0'", FEX)
        self.assertNotIn("*end == '\\\\0'", FEX)
        self.assertIn('for (size_t size : wine_pool_candidates())', FEX)

    def test_no_unvalidated_executable_mapping(self):
        self.assertIn('if (!debugger_attached())', FEX)
        self.assertIn('if (!acceptable_pool(rx, size))', FEX)
        self.assertIn('vm_protect(mach_task_self(), rw, size, FALSE,', FEX)
        self.assertIn('VM_PROT_READ | VM_PROT_WRITE', FEX)
        self.assertIn('return executable_mapping(address, size);', FEX)
        self.assertNotIn('MAP_JIT | MAP_ANON', FEX)

if __name__ == "__main__":
    unittest.main()
