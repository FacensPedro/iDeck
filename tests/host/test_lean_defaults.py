import unittest

from support import repo_text


class LeanDefaultsTests(unittest.TestCase):
    def test_wine_logs_only_exceptions_by_default(self):
        self.assertIn('setenv("WINEDEBUG", "-all,err+seh,err+process", 1)', repo_text("iDeck/WindowsEnvironment.swift"))

    def test_new_games_default_to_30_fps(self):
        self.assertIn('var fpsLimit: String = "30"', repo_text("iDeck/WindowsLibraryModels.swift"))


if __name__ == "__main__":
    unittest.main()
