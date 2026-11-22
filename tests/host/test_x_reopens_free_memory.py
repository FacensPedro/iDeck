import unittest

from support import patch_group, repo_text

COORD = repo_text("iDeck/SystemCoordinator.swift")
STIK = repo_text("iDeck/MadeiraJIT/StikJITHelper.swift")
APP = repo_text("iDeck/iDeckApp.swift")
FDT = repo_text("patches/madeira-fdt-no-teb.patch")


class XReopensWithFreeMemoryTests(unittest.TestCase):
    def test_fresh_instance_url_has_no_pid(self):
        start = STIK.index("static func requestFreshInstance")
        body = STIK[start:STIK.index("\n    }\n", start)]
        self.assertIn("bundle-id", body)
        self.assertIn("script-data", body)
        self.assertNotIn("pid", body)
        self.assertNotIn("exit(0)", body)

    def test_x_and_force_close_reopen_through_stikdebug(self):
        self.assertIn("func reopenWithFreeMemory(reason: String, exitAnyway: Bool = true) -> Bool", COORD)
        self.assertIn('reopenWithFreeMemory(reason: "the X closed a running session")', COORD)
        self.assertIn('reopenWithFreeMemory(reason: "the game did not exit")', COORD)
        self.assertIn("StikJITHelper.requestFreshInstance", COORD)

    def test_new_process_notes_the_reopen(self):
        self.assertIn("SystemCoordinator.noteFreshInstanceAfterRelaunch()", APP)


class FdLedgerWithoutTEBTests(unittest.TestCase):
    def test_patch_is_listed_and_guards_null_teb(self):
        self.assertEqual(patch_group("madeira-fdt-no-teb.patch"), "native")
        self.assertIn("return teb ? (unsigned int)HandleToULong( teb->ClientId.UniqueThread ) : 0;", FDT)
        added = [l for l in FDT.splitlines() if l.startswith("+") and not l.startswith("+++") and not l.lstrip("+ ").startswith("*")]
        self.assertFalse(any("GetCurrentThreadId()" in l for l in added))


if __name__ == "__main__":
    unittest.main()
