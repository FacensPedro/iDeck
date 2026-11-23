"""The executable window's widening is reused by the next session of a run (2.13.3)."""
import pathlib
import unittest

SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "MadeiraJIT" / "StikJITHelper.swift").read_text()


class ExeWindowTests(unittest.TestCase):
    def test_extension_tracked_and_reused(self):
        self.assertIn("private static var exeWinExtension: (base: vm_address_t, size: vm_address_t)?", SRC)
        self.assertIn("let heldSize = exeWinExtension?.size ?? 0", SRC)
        self.assertIn("exeWinExtension = (base: exeWinBase + 0x8000000, size: heldSize + extSize)", SRC)

    def test_released_when_not_needed(self):
        self.assertIn("if let held = exeWinExtension, !(exeWinWantedMB > 0 && windowHeld) {", SRC)


if __name__ == "__main__":
    unittest.main()
