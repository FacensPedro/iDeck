import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / "iDeck" / name).read_text()


class EpicBaseAndDLCTests(unittest.TestCase):
    def test_downloader_installs_base_files_only(self):
        d = read("EpicDownloader.swift")
        self.assertIn("includeTags: Set<String> = []", d)
        self.assertIn("manifest.installFiles(includeTags: includeTags)", d)
        formats = read("EpicFormats.swift")
        self.assertIn("!includeTags.isDisjoint(with: file.installTags)", formats)
        self.assertIn("for file in installFiles()", formats)
        self.assertIn("seen.insert(part.guid).inserted", formats)

    def test_dlc_listed_installed_and_removed(self):
        api = read("EpicAPI.swift")
        self.assertIn('mainGameID: (item["mainGameItem"] as? [String: Any])?["id"] as? String', api)
        lib = read("EpicLibrary.swift")
        for needle in ("@Published private(set) var dlcs: [String: [EpicOwnedDLC]]", "func installDLC(_ dlcApp: String)",
                       "func uninstallDLC(_ dlcApp: String)", "private func installDLCFiles(", "epic-installed-dlc.json",
                       "if let entry = dlcEntry(app) {"):
            self.assertIn(needle, lib)
        view = read("MainView.swift")
        self.assertIn('DetailCard(title: tr("DLCs")) { epicDLCList(list) }', view)
        self.assertIn("epic.uninstallDLC(dlc.appName)", view)


if __name__ == "__main__":
    unittest.main()
