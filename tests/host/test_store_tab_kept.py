"""The chosen store tab survives the return from StikDebug (2.13.3)."""
import pathlib
import unittest

VIEW = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "MainView.swift").read_text()


class StoreTabTests(unittest.TestCase):
    def test_saved_and_restored(self):
        self.assertIn("@State var shelf: ShelfItem = .store(ShelfItem.savedStore)", VIEW)
        self.assertIn('@AppStorage("library.lastStore") private var lastStore = "steam"', VIEW)
        self.assertIn("if case .store(let store) = item { lastStore = ShelfItem.storeKey(store) }", VIEW)
        self.assertIn("shelfGames.contains(shelf) ? shelf : .store(ShelfItem.savedStore)", VIEW)


if __name__ == "__main__":
    unittest.main()
