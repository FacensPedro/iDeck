"""32-bit programs return from window callbacks without unwinding (2.13.1).

BioShock 2 (Wine log, 2026-11-23): wined3d's DllMain created a window, the 32-bit
callback returned through wow64_NtCallbackReturn's longjmp, RtlUnwind could not walk
FEX's translated frames (no unwind data), looped in RtlVirtualUnwind2 and ended in
c0000026, then a stack overflow (c00000fd) that closed the game.
"""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "wine-wow64-callback-return-no-unwind.patch").read_text()
SERIES = (ROOT / "patches" / "series.txt").read_text()


class Wow64CallbackReturnTests(unittest.TestCase):
    def test_listed_in_the_wine_group_after_the_other_wine_patches(self):
        line = "wine      wine   wine-wow64-callback-return-no-unwind.patch"
        self.assertIn(line, SERIES)
        self.assertLess(SERIES.index("wine-ios-fault-address.patch"), SERIES.index(line))
        self.assertLess(SERIES.index(line), SERIES.index("# DXMT's iOS cache/sync work"))

    def test_callback_return_clears_the_frame(self):
        self.assertIn("+++ b/dlls/wow64/syscall.c", PATCH)
        self.assertIn("+#ifdef __arm64ec__", PATCH)
        self.assertIn("+    ((_JUMP_BUFFER *)frame->jmpbuf)->Frame = 0;", PATCH)
        self.assertLess(PATCH.index("->Frame = 0;"), PATCH.index(" longjmp( frame->jmpbuf, 1 );"))

    def test_longjmp_without_frame_restores_directly(self):
        self.assertIn("+++ b/dlls/ntdll/signal_arm64ec.c", PATCH)
        self.assertIn("+    if (!buf->Frame)", PATCH)
        self.assertIn("+        RtlCaptureContext( &context );", PATCH)
        self.assertIn("+        context.Rcx = retval;", PATCH)
        self.assertIn("+        RtlRestoreContext( &context, &rec );", PATCH)
        # Before the unwind, which stays for every buffer that has a frame.
        self.assertLess(PATCH.index("if (!buf->Frame)"), PATCH.index(" RtlUnwind( (void *)buf->Frame"))

    def test_only_adds_lines(self):
        removed = [l for l in PATCH.splitlines() if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [])


if __name__ == "__main__":
    unittest.main()
