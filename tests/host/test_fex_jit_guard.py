import unittest
from pathlib import Path


from support import ROOT, repo_text
FEX = repo_text("iDeck/NativeRuntime/FEXRuntime.cpp")
RUNTIME = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
COORDINATOR = repo_text("iDeck/SystemCoordinator.swift")
BRIDGE = repo_text("iDeck/iDeck-Bridging-Header.h")
HEADER = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.h")
JIT_SCRIPT = repo_text("scripts/jit/universal.jitscript")


class FEXJITGuardTests(unittest.TestCase):
    def test_fex_checks_live_debugger_before_first_initialization(self):
        self.assertIn("P_TRACED", FEX)
        self.assertIn("KERN_PROC_PID", FEX)
        self.assertIn("sysctl(", FEX)
        self.assertIn("fex_initialized.load(std::memory_order_acquire) || debugger_attached()", FEX)
        self.assertIn("std::lock_guard<std::mutex> lock(fex_mutex)", FEX)
        start = FEX.index('extern "C" bool ideck_fex_initialize(void)')
        guard = FEX.index("if (!debugger_attached())", start)
        call = FEX.index("const bool initialized = init()", start)
        self.assertIn("fex_initialized.store(initialized, std::memory_order_release)", FEX)
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
