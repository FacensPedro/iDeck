import unittest

from support import repo_text


class DockInstallersCmdSkipTests(unittest.TestCase):
    def test_missing_cmd_skips_installers_without_forging_and_starts_game(self):
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        installers = repo_text("iDeck/Vendor/Madeira/DockInstallers.swift")
        self.assertIn("DockInstallers.skipScript()", coordinator)
        self.assertNotIn("Steam's one-time installers could not start because Wine cmd.exe", coordinator)
        self.assertIn("static func skipScript()", installers)
        skip = installers.split("static func skipScript()", 1)[1].split("}", 1)[0]
        self.assertNotIn("HasRun", skip)


if __name__ == "__main__":
    unittest.main()
