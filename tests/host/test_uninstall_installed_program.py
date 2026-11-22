import unittest

from support import repo_text

LIB = repo_text("iDeck/WindowsLibraryModels.swift")


class UninstallInstalledProgramTests(unittest.TestCase):
    def test_installed_programs_remove_their_folder_and_shortcuts(self):
        start = LIB.index("func uninstallExecutable(at url: URL, prefixPath: URL) throws")
        body = LIB[start:LIB.index("let id = profileID(for: target)", start)]
        self.assertIn("try uninstallInstalledProgram(at: target, prefixPath: prefixPath)", body)
        self.assertIn("nonisolated static func installFolder(of exe: URL, drive: URL) -> URL?", LIB)
        self.assertIn("static func shortcutFiles(in drive: URL) -> [(file: URL, exe: URL)]", LIB)
        self.assertNotIn("refused to remove a file outside", LIB)

    def test_shared_folders_are_never_removed_whole(self):
        start = LIB.index("nonisolated static let sharedFolders")
        shared = LIB[start:LIB.index("]", start)]
        for name in ("program files", "program files (x86)", "windows", "users", "desktop", "ea games", "ubisoft", "steam"):
            self.assertIn(f'"{name}"', shared)

    def test_nothing_is_removed_while_wine_runs(self):
        start = LIB.index("private func uninstallInstalledProgram")
        self.assertIn("!ideck_wineprocess_running()", LIB[start:start + 400])


if __name__ == "__main__":
    unittest.main()
