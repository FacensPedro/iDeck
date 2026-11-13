import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class AfterSessionReclaimTests(unittest.TestCase):
    def test_overlay_idempotent_and_wired(self):
        self.assertIn('scripts/apply_madeira_wow_reclaim.py" "$DEST"', (ROOT / "scripts/fetch_madeira_sources.sh").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "build/ntdll-unix/virtual_ios.c"
            src.parent.mkdir(parents=True)
            src.write_text("static void ios_wow_reclaim_dead_windows(void)\n{\n}\n\n"
                           "/***********************************************************************\n"
                           " *           ios_wow_window_reserve\n")
            for _ in range(2):
                subprocess.run([sys.executable, str(ROOT / "scripts/apply_madeira_wow_reclaim.py"), tmp], check=True)
            self.assertEqual(src.read_text().count("int ideck_wow_reclaim_dead_windows(void)"), 1)

    def test_app_calls_it_after_the_session(self):
        coord = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn("Self.reclaimAfterSession()", coord)
        self.assertIn("ideck_wow_reclaim_after_session()", coord)
        bridge = (ROOT / "iDeck/NativeRuntime/WineBridge.mm").read_text()
        self.assertIn("int ideck_wow_reclaim_after_session(void)", bridge)

    def test_ea_size_request_survives_cancellation(self):
        ea = (ROOT / "iDeck/EALibrary.swift").read_text()
        self.assertIn("let cancelled = error is CancellationError", ea)
        self.assertIn("if !cancelled {", ea)


if __name__ == "__main__":
    unittest.main()
