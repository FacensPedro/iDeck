import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class InstallerReplacedTests(unittest.TestCase):
    def test_launch_noted_and_installer_hidden(self):
        lib = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
        self.assertIn("nonisolated static func noteLaunch(of url: URL)", lib)
        self.assertIn("let added = installedNow.subtracting(before)", lib)
        self.assertIn("executableURLs = executableURLs.filter { hidden[$0.lastPathComponent.lowercased()] == nil }", lib)
        self.assertIn('if launcher == ".exe" { WindowsLibraryStore.noteLaunch(of: url) }',
                      (ROOT / "iDeck/SystemCoordinator.swift").read_text())


if __name__ == "__main__":
    unittest.main()
