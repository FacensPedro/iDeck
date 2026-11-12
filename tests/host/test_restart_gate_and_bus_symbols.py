import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class RestartGateTests(unittest.TestCase):
    def test_launch_refused_when_restart_needed(self):
        gate = COORD[COORD.index("private func previousWineSessionStillFinishing"):]
        gate = gate[:gate.index("// A Windows guest runs as a thread")]
        self.assertIn("if let why = Self.restartNeeded()", gate)

    def test_reasons(self):
        self.assertIn("Self.restartReason = \"the last game crashed", COORD)
        self.assertIn("StikJITHelper.smallPoolMB > 0", COORD)
        self.assertIn("static let restartMinimumFreeMiB = 1500", COORD)


class BusSymbolsTests(unittest.TestCase):
    def test_applier_is_idempotent_and_wired(self):
        fetch = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
        self.assertIn('scripts/apply_madeira_bus_symbols.py" "$DEST"', fetch)
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "build/ntdll-unix/signal_arm64_ios.c"
            src.parent.mkdir(parents=True)
            src.write_text('#include <dlfcn.h>\n    {\n        ERR("BUS");\n            bus_pc_ok ? "" : " <unmappable PC>");\n    }\n')
            for _ in range(2):
                subprocess.run([sys.executable, str(ROOT / "scripts/apply_madeira_bus_symbols.py"), tmp], check=True)
            self.assertEqual(src.read_text().count("[bus-sym]"), 2)  # comment + ERR, once


if __name__ == "__main__":
    unittest.main()
