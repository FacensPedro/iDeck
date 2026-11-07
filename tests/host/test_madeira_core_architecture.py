import unittest
from pathlib import Path

from support import ROOT, repo_text
class MadeiraCoreArchitectureTests(unittest.TestCase):
    def test_config_settings_use_single_snapshot(self):
        config = repo_text("iDeck/MadeiraConfig.swift")
        self.assertIn("private static func snapshot() -> (exists: Bool, values: [String: String])", config)
        self.assertIn("static func all() -> [String: String] { snapshot().values }", config)
        get_body = config.split("static func get(_ key: String) -> String? {", 1)[1].split("\n    }", 1)[0]
        flag_body = config.split("static func flag(_ name: String, fallback: Bool = true) -> Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertEqual(get_body.count("snapshot()"), 1)
        self.assertEqual(flag_body.count("snapshot()"), 1)
        self.assertNotIn("presentCached", config)
        self.assertIn('madeira-\\(key).txt', get_body)
        self.assertIn("info.st_ino", config)

    def test_native_jit_and_wine_ownership_remains_intact(self):
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertIn("guard ensureJITForGameLaunch() else { return }", coordinator)


if __name__ == "__main__":
    unittest.main()
