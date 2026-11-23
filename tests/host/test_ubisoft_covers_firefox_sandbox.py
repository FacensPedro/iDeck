import unittest

from support import repo_text

UBI = repo_text("iDeck/UbisoftLibrary.swift")
VIEW = repo_text("iDeck/MainView.swift")
ENV = repo_text("iDeck/WindowsEnvironment.swift")


class UbisoftCoverTests(unittest.TestCase):
    def test_covers_come_from_steam_by_title(self):
        self.assertIn("var coverURLs: [URL] = []", UBI)
        self.assertIn("store.steampowered.com/api/storesearch/", UBI)
        self.assertIn("library_600x900.jpg", UBI)
        self.assertIn("await self.findCovers()", UBI)

    def test_card_shows_the_cover(self):
        start = VIEW.index("private func ubisoftCard(")
        card = VIEW[start:VIEW.index("private func launchEAGame", start)]
        self.assertIn("GOGArtworkView(urls: game.coverURLs, fallbackColor: secondaryColor, fill: true, fallbackTitle: game.title)", card)


class FirefoxSandboxTests(unittest.TestCase):
    def test_every_launch_turns_mozilla_sandboxes_off(self):
        self.assertIn("Self.turnOffFirefoxSandbox(binary: binary)", ENV)
        for name in ("MOZ_DISABLE_CONTENT_SANDBOX", "MOZ_DISABLE_GPU_SANDBOX", "MOZ_DISABLE_RDD_SANDBOX",
                     "MOZ_DISABLE_SOCKET_PROCESS_SANDBOX", "MOZ_DISABLE_UTILITY_SANDBOX"):
            self.assertIn(f'"{name}"', ENV)

    def test_tor_profile_gets_user_js_once(self):
        self.assertIn('"TorBrowser"', ENV)
        self.assertIn("Data/Browser/profile.default", ENV)
        self.assertIn("guard !text.contains(firefoxUserJSMarker) else { continue }", ENV)
        self.assertIn('security.sandbox.content.level\\", 0', ENV)


if __name__ == "__main__":
    unittest.main()
