"""Epic optional content (install tags in a game's own build) installs separately."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = (ROOT / "iDeck/EpicLibrary.swift").read_text()
VIEW = (ROOT / "iDeck/MainView.swift").read_text()


class EpicOptionalContentTests(unittest.TestCase):
    def test_install_uses_the_chosen_tags(self):
        self.assertIn("var selectedTags: [String]?", LIBRARY)
        self.assertIn("includeTags: Set(record?.selectedTags ?? [])) { progress in", LIBRARY)
        self.assertIn("selectedTags: installed[app]?.selectedTags)", LIBRARY)

    def test_add_and_remove_one_pack(self):
        self.assertIn("func installPack(_ app: String, tag: String) {", LIBRARY)
        self.assertIn("enqueue(app, kind: .update)", LIBRARY)
        self.assertIn("func uninstallPack(_ app: String, tag: String) {", LIBRARY)
        # Files the base game or another installed pack needs stay.
        self.assertIn("file.installTags.contains(tag) && remaining.isDisjoint(with: file.installTags)", LIBRARY)

    def test_listed_on_the_game_page(self):
        self.assertIn('DetailCard(title: tr("Optional content")) { epicPackList(packs) }', VIEW)
        self.assertIn("await epic.loadOptionalPacks(appName)", VIEW)


if __name__ == "__main__":
    unittest.main()
