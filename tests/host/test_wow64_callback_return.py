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

    def test_only_ntdll_is_patched(self):
        # 2.13.3: the build recompiles ntdll.dll only; wow64.dll is Madeira's prebuilt
        # binary, so a wow64/syscall.c hunk (2.13.1) never reached the app.
        self.assertNotIn("dlls/wow64/", PATCH)
        self.assertEqual(PATCH.count("+++ b/"), 1)
        self.assertIn("+++ b/dlls/ntdll/signal_arm64ec.c", PATCH)

    def test_wow64_callback_buffer_recognised(self):
        self.assertIn("NtCurrentTeb()->WowTebOffset", PATCH)
        self.assertIn("TlsSlots[WOW64_TLS_USERCALLBACKDATA]", PATCH)
        self.assertIn("(ULONG_PTR)buf - callback <= 64", PATCH)
        self.assertIn("if (wow64_callback || !buf->Frame)", PATCH)

    def test_longjmp_without_frame_restores_directly(self):
        self.assertIn("+++ b/dlls/ntdll/signal_arm64ec.c", PATCH)
        self.assertIn("+            RtlCaptureContext( &context );", PATCH)
        self.assertIn("+            context.Rcx = retval;", PATCH)
        self.assertIn("+            RtlRestoreContext( &context, &rec );", PATCH)
        # Before the unwind, which stays for every buffer that has a frame.
        self.assertLess(PATCH.index("if (wow64_callback || !buf->Frame)"), PATCH.index(" RtlUnwind( (void *)buf->Frame"))

    def test_arm64_caller_gets_every_saved_register(self):
        # 2.15.0: Duke Nukem 3D, Overcooked and Max Payne 2 crashed in wow64win.dll
        # (null + 0xc) after a window callback: wow64.dll uses x28 right after its
        # setjmp returns, and an AMD64 CONTEXT cannot carry x23, x24 or x28.
        self.assertIn('+         "stp x23, x24, [x0, #0x60]', PATCH)
        self.assertIn('+         "str x28,      [x0, #0x70]', PATCH)
        self.assertIn("+static void __attribute__((naked,noreturn)) ios_arm64_longjmp", PATCH)
        self.assertIn('+         "ldp x23, x24, [x0, #0x60]', PATCH)
        self.assertIn('+         "ldr x28,      [x0, #0x70]', PATCH)
        self.assertIn('+         "csinc w0, w1, wzr, ne', PATCH)
        self.assertIn("if (wow64_callback && !RtlIsEcCode( (ULONG_PTR)buf->Rip )) ios_arm64_longjmp( buf, retval );", PATCH)
        self.assertLess(PATCH.index("ios_arm64_longjmp( buf, retval );"), PATCH.index("if (wow64_callback || !buf->Frame)"))

    def test_only_adds_lines(self):
        removed = [l for l in PATCH.splitlines() if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [])


if __name__ == "__main__":
    unittest.main()
