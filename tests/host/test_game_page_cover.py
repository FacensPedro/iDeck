import unittest

from support import repo_text

VIEW = repo_text("iDeck/MainView.swift")


class GamePageCoverTests(unittest.TestCase):
    def test_cover_tap_plays_and_hold_opens_details(self):
        page = VIEW.split("private func gamePage(_ item: ShelfItem) -> some View {", 1)[1].split("private func launchFromCover", 1)[0]
        self.assertIn(".onLongPressGesture(minimumDuration: 0.4) { openSettings(item) }", page)
        self.assertIn(".onTapGesture { launchFromCover(item) }", page)
        self.assertNotIn("gameAction(item)", page)
        self.assertNotIn("gearshape.fill", page)
        self.assertNotIn("private func gameAction(", VIEW)


if __name__ == "__main__":
    unittest.main()
