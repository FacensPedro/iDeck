import unittest

from support import repo_text


class CupheadBendyFixesTests(unittest.TestCase):
    def test_directx_setup_is_left_out_without_recording(self):
        installers = repo_text("iDeck/Vendor/Madeira/DockInstallers.swift")
        self.assertIn('pending.removeAll { $0.executable.lowercased().hasSuffix("dxsetup.exe") }', installers)

    def test_old_896_mb_pool_moves_to_624_once(self):
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertIn('UserDefaults.standard.object(forKey: "wineJITPoolMiB") as? Int == 896', coordinator)
        self.assertIn('"wineJITPool624Migrated"', coordinator)


if __name__ == "__main__":
    unittest.main()
