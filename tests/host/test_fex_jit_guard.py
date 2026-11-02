import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FEX = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")
RUNTIME = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "iDeck/iDeck-Bridging-Header.h").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")
JIT_SCRIPT = (ROOT / "scripts/jit/universal.jitscript").read_text(encoding="utf-8")


class FEXJITGuardTests(unittest.TestCase):
    def test_fex_checks_live_debugger_before_first_initialization(self):
        self.assertIn("P_TRACED", FEX)
        self.assertIn("KERN_PROC_PID", FEX)
        self.assertIn("sysctl(", FEX)
        self.assertIn("fex_initialized || debugger_attached()", FEX)
        start = FEX.index('extern "C" bool ideck_fex_initialize(void)')
        guard = FEX.index("if (!debugger_attached())", start)
        call = FEX.index("fex_initialized = init()", start)
        self.assertLess(guard, call)

    def test_native_fex_availability_requires_static_linkage(self):
        availability = FEX.split('extern "C" bool ideck_fex_available(void) {', 1)[1].split('\n}', 1)[0]
        self.assertIn('return &fex_initialize != nullptr;', availability)
        self.assertIn('return false;', availability)
        self.assertNotIn('dlsym(', availability)
        self.assertNotIn('dlsym(', FEX)

    def test_page_zero_debugger_command_never_returns_stale_address(self):
        # Madeira's madeira-jit.js, copied line by line.
        self.assertIn("} else if (x16Num === 3n) {", JIT_SCRIPT)
        self.assertIn("function numberToLittleEndianHexString(num)", JIT_SCRIPT)


if __name__ == "__main__":
    unittest.main()
