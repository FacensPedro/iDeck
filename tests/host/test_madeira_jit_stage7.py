import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CPP = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
POLICY = (ROOT / "iDeck/NativeRuntime/JITRegionPolicy.h").read_text(encoding="utf-8")


class MadeiraStage7JITTests(unittest.TestCase):
    def test_read_only_snapshot_has_no_debugger_trap_and_never_blocks_ux(self):
        start = CPP.index('extern "C" IDeckJITSnapshot ideck_jit_snapshot(void)')
        body = CPP[start:]
        self.assertIn("fex_mutex.try_lock()", body)
        self.assertIn("wine_pool_mutex.try_lock()", body)
        self.assertIn("state.debugger_attached = debugger_attached()", body)
        self.assertIn("state.wine_state_busy = true", body)
        self.assertNotIn("jit26_prepare_region(", body)
        self.assertNotIn("vm_remap(", body)
        self.assertNotIn("vm_protect(", body)
        self.assertNotIn("fex_initialize(", body)

    def test_rx_and_rw_must_have_strict_disjoint_wx_protections(self):
        self.assertIn("#include \"JITRegionPolicy.h\"", CPP)
        self.assertIn("ideck::jit::executable_only", CPP)
        self.assertIn("ideck::jit::writable_only", CPP)
        self.assertIn("ideck::jit::disjoint", CPP)
        self.assertIn("if (!writable_mapping(alias, size))", CPP)
        self.assertIn("if (!acceptable_pool(rx, size))", CPP)
        self.assertLess(CPP.index("if (!writable_mapping(alias, size))"),
                        CPP.index("if (!export_pool(rx, alias, size))"))
        self.assertIn("UINTPTR_MAX - size", POLICY)
        self.assertIn("(current & execute) == execute && (current & write) == 0", POLICY)
        self.assertIn("(current & execute) == 0", POLICY)

    def test_c_abi_snapshot_and_stage_errors_are_explicit(self):
        self.assertIn("IDeckJITSnapshot ideck_jit_snapshot(void);", HEADER)
        for field in (
            "debugger_attached", "fex_initialized", "fex_state_busy",
            "wine_pool_prepared", "wine_state_busy", "rx_executable",
            "rw_writable", "wine_failure_stage", "wine_failure_rx_detail",
            "wine_failure_mach_code", "wine_pool_mib",
        ):
            self.assertIn(field, HEADER)

    def test_settings_copies_read_only_on_device_evidence_without_exposing_addresses(self):
        self.assertIn("private func copyJITDiagnostics()", SETTINGS)
        self.assertIn("let snapshot = ideck_jit_snapshot()", SETTINGS)
        self.assertIn("UIPasteboard.general.string = values.joined", SETTINGS)
        self.assertIn('tr("Copy JIT diagnostics")', SETTINGS)
        self.assertIn("JIT guest code execution: NOT TESTED by this snapshot", SETTINGS)
        self.assertNotIn("String(format: \"%p\"", SETTINGS)

    def test_existing_stikdebug_brk_guards_remain(self):
        self.assertIn("if (!debugger_attached())", CPP)
        self.assertIn("return fex_initialized || debugger_attached();", CPP)
        self.assertIn("jit26_prepare_region(nullptr, size)", CPP)

    def test_portable_policy_compiles_and_executes(self):
        source = ROOT / "tests/host/JITRegionPolicyTests.cpp"
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "ideck-jit-region-policy-tests"
            subprocess.run(["c++", "-std=c++20", "-O2", str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
