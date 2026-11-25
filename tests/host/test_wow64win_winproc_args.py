"""wow64_NtUserCallWinProc keeps its argument in memory across the 32-bit callback (2.16.2)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "wine-wow64win-winproc-callback-args.patch").read_text()
SERIES = (ROOT / "patches" / "series.txt").read_text()


class WinProcCallbackArgs(unittest.TestCase):
    def test_in_series_after_atoms(self):
        lines = [l.split() for l in SERIES.splitlines() if l and not l.startswith("#")]
        names = [l[2] for l in lines if len(l) == 3]
        self.assertIn(["wine", "wine", "wine-wow64win-winproc-callback-args.patch"], lines)
        self.assertLess(names.index("wine-wow64win-atoms.patch"),
                        names.index("wine-wow64win-winproc-callback-args.patch"))

    def test_pointer_reread_after_callback(self):
        self.assertIn("+    void * volatile saved_arg;", PATCH)
        self.assertIn("+    saved_arg = arg;", PATCH)
        self.assertIn("+    params32 = saved_arg;", PATCH)
        self.assertIn("+    if (!status && ret_ptr && ret_len >= sizeof(LONG))", PATCH)


if __name__ == "__main__":
    unittest.main()
