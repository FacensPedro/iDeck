"""The thread-name exception left unhandled in a WoW64 process continues (2.15.1).

2.15.0 patched dlls/ntdll/unix/thread.c, which iOS builds never compile: Madeira's
build/ntdll-unix/thread_ios.c replaces it (build.sh compile_one thread_ios.c), so
Assassin's Creed IV still ended on 0x406D1388. The rule now lives there, next to
Madeira's own DBG_PRINTEXCEPTION swallow.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "madeira-thread-name-exception.patch").read_text()
SERIES = (ROOT / "patches" / "series.txt").read_text()


class ThreadNameExceptionTests(unittest.TestCase):
    def test_listed_in_the_early_group_after_the_cpu_area_patch(self):
        line = "early     .      madeira-thread-name-exception.patch"
        self.assertIn(line, SERIES)
        self.assertLess(SERIES.index("madeira-arm64-cpu-area.patch"), SERIES.index(line))
        self.assertNotIn("wine-ignore-debugger-only-exceptions.patch", SERIES)

    def test_patches_the_file_ios_compiles(self):
        self.assertIn("+++ b/build/ntdll-unix/thread_ios.c", PATCH)
        self.assertEqual(PATCH.count("+++ b/"), 1)
        build_file = ROOT / "vendor/Madeira/build/ntdll-unix/build.sh"
        if not build_file.exists():
            return  # the Madeira checkout is not part of every CI job
        build = build_file.read_text()
        self.assertIn('compile_one "$BUILD_DIR/thread_ios.c" "thread"', build)

    def test_continues_instead_of_terminating(self):
        self.assertIn("+    if (rec->ExceptionCode == 0x406d1388)", PATCH)
        self.assertIn("+        return NtContinue( context, FALSE );", PATCH)

    def test_first_chance_returns_without_dispatch(self):
        # The WoW64 raise carries pc=0: dispatching or NtContinue jumps to 0 (2.16.1).
        self.assertIn("+    if (rec && rec->ExceptionCode == 0x406d1388 && first_chance)", PATCH)
        self.assertIn("+        return STATUS_SUCCESS;", PATCH)
        first = PATCH.index("first_chance)")
        self.assertLess(first, PATCH.index("+     status = send_debug_event") if "+     status = send_debug_event" in PATCH else PATCH.index(" status = send_debug_event"))

    def test_only_adds_lines(self):
        removed = [l for l in PATCH.splitlines() if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [])


if __name__ == "__main__":
    unittest.main()
