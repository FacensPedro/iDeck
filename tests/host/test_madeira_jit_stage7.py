import subprocess
import tempfile
import unittest
from pathlib import Path

from support import ROOT, repo_text
CPP = repo_text("iDeck/NativeRuntime/FEXRuntime.cpp")
HEADER = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.h")
SETTINGS = repo_text("iDeck/SettingsView.swift")
POLICY = repo_text("iDeck/NativeRuntime/JITRegionPolicy.h")


class MadeiraStage7JITTests(unittest.TestCase):
    def test_c_abi_snapshot_and_stage_errors_are_explicit(self):
        self.assertIn("IDeckJITSnapshot ideck_jit_snapshot(void);", HEADER)
        for field in (
            "debugger_attached", "fex_initialized", "fex_state_busy",
            "wine_pool_prepared", "wine_state_busy", "rx_executable",
            "rw_writable", "wine_failure_stage", "wine_failure_rx_detail",
            "wine_failure_mach_code", "wine_pool_mib",
        ):
            self.assertIn(field, HEADER)

    def test_settings_no_longer_copies_jit_diagnostics(self):
        # JIT problems are reported in Bugs & logs instead.
        self.assertNotIn("copyJITDiagnostics", SETTINGS)
        self.assertNotIn("UIPasteboard.general.string = values.joined", SETTINGS)
        self.assertNotIn("String(format: \"%p\"", SETTINGS)

    def test_portable_policy_compiles_and_executes(self):
        source = ROOT / "tests/host/JITRegionPolicyTests.cpp"
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "ideck-jit-region-policy-tests"
            subprocess.run(["c++", "-std=c++20", "-O2", str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
