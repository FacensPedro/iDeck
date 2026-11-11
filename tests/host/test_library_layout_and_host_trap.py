"""Library layout fixes and the runtime-raised illegal instruction."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = (ROOT / "iDeck/MainView.swift").read_text()
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()


class LibraryLayoutTests(unittest.TestCase):
    def test_card_titles_are_centered(self):
        start = VIEW.index("    private func cardTitle(_ title: String)")
        card = VIEW[start:VIEW.index("\n    }\n", start)]
        self.assertIn(".multilineTextAlignment(.center)", card)
        self.assertIn(".frame(maxWidth: .infinity, alignment: .top)", card)
        self.assertNotIn("topLeading", card)

    def test_shelf_row_leaves_room_for_the_selected_tile(self):
        start = VIEW.index("    var consoleShelf: some View")
        shelf = VIEW[start:VIEW.index("    private var shelfTileWidth", start)]
        self.assertIn(".padding(.horizontal, 14)", shelf)
        self.assertNotIn(".padding(.horizontal, 2)", shelf)


class HostTrapTests(unittest.TestCase):
    def test_runtime_trap_does_not_turn_avx_on(self):
        self.assertIn("enum IllegalInstructionOrigin", ENVIRONMENT)
        self.assertIn("static let guestBase: UInt64 = 0x70_0000_0000", ENVIRONMENT)
        self.assertIn('"Unhandled exception code c000001d"', ENVIRONMENT)
        host = COORDINATOR.index("if hostTrap {")
        avx = COORDINATOR.index("AVXAuto.enable(endedGame)")
        self.assertLess(host, avx)
        self.assertIn("} else if ntstatus == 0xC000001D, let endedGame, AVXAuto.enable(endedGame)", COORDINATOR)

    def test_origin_is_read_before_the_log_offset_is_cleared(self):
        read = COORDINATOR.index("IllegalInstructionOrigin.isHost(logURL: Self.wineLogURL, since: wineLogStartOffset)")
        self.assertLess(read, COORDINATOR.index("wineLogStartOffset = nil", read))


if __name__ == "__main__":
    unittest.main()
