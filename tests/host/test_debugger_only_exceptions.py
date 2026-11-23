"""Debugger-only exceptions left unhandled in a WoW64 process return to their caller (2.14.1)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "wine-ignore-debugger-only-exceptions.patch").read_text()
SERIES = (ROOT / "patches" / "series.txt").read_text()


class DebuggerOnlyExceptionTests(unittest.TestCase):
    def test_listed_in_the_wine_group(self):
        self.assertIn("wine      wine   wine-ignore-debugger-only-exceptions.patch", SERIES)

    def test_codes_and_return(self):
        self.assertIn("+++ b/dlls/ntdll/unix/thread.c", PATCH)
        for code in ("0x406d1388", "DBG_PRINTEXCEPTION_C", "DBG_PRINTEXCEPTION_WIDE_C"):
            self.assertIn(code, PATCH)
        self.assertIn("+        return STATUS_SUCCESS;", PATCH)
        self.assertLess(PATCH.index("first_chance) return call_user_exception_dispatcher"), PATCH.index("ignoring unhandled"))

    def test_only_adds_lines(self):
        self.assertEqual([l for l in PATCH.splitlines() if l.startswith("-") and not l.startswith("---")], [])


if __name__ == "__main__":
    unittest.main()
