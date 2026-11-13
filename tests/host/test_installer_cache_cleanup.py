import unittest
from pathlib import Path

LIB = (Path(__file__).resolve().parents[2] / "iDeck/WindowsLibraryModels.swift").read_text()


class InstallerCacheTests(unittest.TestCase):
    def test_temp_cleaned_after_installer(self):
        self.assertIn("nonisolated static func cleanInstallerCaches(drive: URL)", LIB)
        self.assertIn('if let drive = pending["drive"] { cleanInstallerCaches(drive: URL(fileURLWithPath: drive)) }', LIB)
        block = LIB[LIB.index("static func cleanInstallerCaches"):]
        self.assertIn("guard !ideck_wineprocess_running() else { return }", block)
        self.assertIn('"windows/temp"', block)


if __name__ == "__main__":
    unittest.main()
