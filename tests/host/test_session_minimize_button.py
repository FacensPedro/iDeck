"""The minimize button keeps its place and every game starts minimized (2.14.1)."""
import pathlib
import unittest

SESSION = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "GameSessionView.swift").read_text()


class MinimizeButtonTests(unittest.TestCase):
    def test_starts_minimized_each_game(self):
        self.assertIn("@State private var gameButtonsMinimized = true", SESSION)
        self.assertNotIn('@AppStorage("gameButtonsMinimized")', SESSION)

    def test_same_place_both_states(self):
        for icon in ('"chevron.right.circle.fill"', '"chevron.left.circle.fill"'):
            at = SESSION.index(icon)
            self.assertIn(".padding(.vertical, 8)", SESSION[at:at + 260])


if __name__ == "__main__":
    unittest.main()
