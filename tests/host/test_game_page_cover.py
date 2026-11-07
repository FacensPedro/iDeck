import unittest

from support import repo_text

VIEW = repo_text("iDeck/MainView.swift")


class GamePageCoverTests(unittest.TestCase):
    def test_cover_is_a_backdrop_that_does_nothing(self):
        page = VIEW.split("private func gamePage(_ item: ShelfItem) -> some View {", 1)[1].split("var shelfBackdrop", 1)[0]
        self.assertNotIn("onTapGesture", page)
        self.assertNotIn("onLongPressGesture", page)
        self.assertNotIn("gameHero(item)", page)
        backdrop = VIEW.split("var shelfBackdrop: some View {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn(".allowsHitTesting(false)", backdrop)
        self.assertIn(".blur(radius: 24)", backdrop)
        self.assertIn("shelfBackdrop\n            VStack(spacing: 0) {", VIEW)
        self.assertNotIn("launchFromCover", VIEW)

    def test_game_tile_opens_details_with_launch(self):
        self.assertIn("if case .store = item {} else { openSettings(item) }", VIEW)
        self.assertIn("coordinator: coordinator) { game in launchSteamGame(game) }", VIEW)
        self.assertIn("coordinator.launchWindowsExecutable(at: executableURL, profile: profile)", VIEW)


if __name__ == "__main__":
    unittest.main()
