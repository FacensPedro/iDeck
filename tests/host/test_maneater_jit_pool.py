import unittest

from support import repo_text


class ManeaterJITPoolTests(unittest.TestCase):
    def test_maneater_launcher_and_shipping_executable_use_contiguous_pool(self):
        entries = {}
        for raw in repo_text("jit-pool.txt").splitlines():
            line = raw.split("#", 1)[0].strip()
            if "=" in line:
                name, size = (part.strip() for part in line.split("=", 1))
                entries[name.lower()] = int(size)
        self.assertEqual(entries["maneater.exe"], 512)
        self.assertEqual(entries["maneater-win64-shipping.exe"], 512)

    def test_per_game_pool_precedes_global_pool(self):
        pool = repo_text("iDeck/MadeiraJIT/MadeiraWinePool.swift").split("static var sizeMB: Int", 1)[1].split("static func prepare()", 1)[0]
        self.assertLess(pool.index('MadeiraConfig.gameValue("pool")'),
                        pool.index("JITPoolList.size(forCurrentGame: ())"))
        self.assertLess(pool.index("JITPoolList.size(forCurrentGame: ())"),
                        pool.index('MadeiraConfig.get("pool")'))

    def test_game_executable_is_passed_to_pool_selection_before_allocation(self):
        launcher = repo_text("iDeck/WindowsEnvironment.swift")
        self.assertLess(launcher.index('setenv("IDECK_JIT_GAME_EXE", binary.lastPathComponent, 1)'),
                        launcher.index("MadeiraWinePool.prepare()"))
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertIn("jit-pool.txt in Resources", project)


if __name__ == "__main__":
    unittest.main()
