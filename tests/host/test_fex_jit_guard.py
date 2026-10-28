import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FEX = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")
RUNTIME = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "iDeck/iDeck-Bridging-Header.h").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")
JIT_SCRIPT = (ROOT / "scripts/jit/universal.js").read_text(encoding="utf-8")


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

    def test_wine_requires_a_distinct_dual_mapped_executable_pool(self):
        self.assertIn("bool ideck_wine_jit_pool_prepare(void);", HEADER)
        self.assertIn("bool ideck_wine_jit_pool_ready(void);", HEADER)
        self.assertIn('jit26_prepare_region(nullptr, size)', FEX)
        self.assertIn('64ULL * MiB', FEX)
        self.assertIn('128ULL * MiB', FEX)
        self.assertIn('static_cast<vm_address_t>(0x300000000ULL)', FEX)
        self.assertIn('vm_remap failed size=', FEX)
        self.assertIn('vm_protect(RW) failed size=', FEX)
        self.assertIn('if (!debugger_attached())', FEX)
        self.assertIn("vm_remap(", FEX)
        self.assertIn("VM_PROT_READ | VM_PROT_WRITE", FEX)
        self.assertIn("VM_PROT_EXECUTE", FEX)
        self.assertIn('"WINE_IOS_JIT_RX"', FEX)
        self.assertIn('"WINE_IOS_JIT_RW"', FEX)
        self.assertIn('"WINE_IOS_JIT_SIZE"', FEX)
        self.assertIn("if (!debugger_attached())", FEX)
        self.assertIn("if (!ideck_wine_jit_pool_prepare() || !ideck_wine_jit_pool_ready()) return ENOMEM;", RUNTIME)
        self.assertLess(RUNTIME.index("ideck_wine_jit_pool_prepare()"), RUNTIME.index("ideck_wineserver_initialize(wine_prefix)"))
        self.assertIn("Wine ARM64EC executable JIT pool", COORDINATOR)

    def test_page_zero_debugger_command_never_returns_stale_address(self):
        self.assertIn("const CMD_MAP_PAGE_ZERO = 3;", JIT_SCRIPT)
        self.assertIn("[CMD_MAP_PAGE_ZERO]: JIT26MapPageZero", JIT_SCRIPT)
        self.assertIn("let success = 0n;", JIT_SCRIPT)
        self.assertIn("numberToLittleEndianHexString(success)", JIT_SCRIPT)

    def test_all_windows_launch_paths_check_jit_readiness(self):
        self.assertGreaterEqual(COORDINATOR.count("ideck_fex_jit_ready()"), 3)
        self.assertIn("StikDebug must remain attached", COORDINATOR)
        self.assertIn("JIT permission is present but StikDebug is no longer attached", COORDINATOR)


if __name__ == "__main__":
    unittest.main()
