import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FEX = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")
RUNTIME = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "iDeck/iDeck-Bridging-Header.h").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")


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

    def test_launcher_returns_recoverable_errno_without_jit(self):
        self.assertIn("if (!ideck_fex_jit_ready()) return EPERM;", RUNTIME)
        self.assertIn("if (!ideck_fex_initialize()) return EAGAIN;", RUNTIME)
        self.assertIn("bool ideck_fex_jit_ready(void);", HEADER)
        self.assertIn('NativeRuntime/MadeiraRuntimeBridge.h', BRIDGE)

    def test_all_windows_launch_paths_check_jit_readiness(self):
        self.assertGreaterEqual(COORDINATOR.count("ideck_fex_jit_ready()"), 3)
        self.assertIn("StikDebug must remain attached", COORDINATOR)
        self.assertIn("JIT permission is present but StikDebug is no longer attached", COORDINATOR)


if __name__ == "__main__":
    unittest.main()
