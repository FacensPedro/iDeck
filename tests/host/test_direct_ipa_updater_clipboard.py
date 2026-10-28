import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DirectIPAUpdaterAndClipboardTests(unittest.TestCase):
    def test_ipa_is_uploaded_as_a_raw_file_not_a_second_zip(self):
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        segment = workflow.split("      - name: Upload IPA directly (no outer ZIP)", 1)[1].split("      - name:", 1)[0]
        self.assertIn("uses: actions/upload-artifact@v7", segment)
        self.assertIn("path: iDeck.ipa", segment)
        self.assertIn("archive: false", segment)
        self.assertIn("id: ipa_artifact", segment)
        self.assertIn("steps.ipa_artifact.outputs.artifact-url", workflow)
        self.assertIn("gh release upload", workflow)
        self.assertIn("gh release create", workflow)

    def test_updater_checks_verified_github_ipa_releases(self):
        source = (ROOT / "iDeck/UpdateChecker.swift").read_text()
        settings = (ROOT / "iDeck/SettingsView.swift").read_text()
        self.assertIn("ipa.path.hasPrefix(\"/FacensPedro/iDeck/releases/download/\")", source)
        self.assertIn('parts.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]', source)
        self.assertIn('["sidestore", "altstore"]', source)
        self.assertIn("func openIDeckReleases()", source)
        self.assertIn('actionButton(title: tr("Open iDeck releases")', settings)
        self.assertIn('actionButton(title: tr("Update iDeck %@", update.latest ?? "")', settings)
        self.assertIn("iDeck cannot replace its own app binary", settings)

    def test_copy_log_is_one_tap_and_bounded(self):
        view = (ROOT / "iDeck/GameSessionView.swift").read_text()
        helper = (ROOT / "iDeck/WineLogClipboard.swift").read_text()
        project = (ROOT / "iDeck.xcodeproj/project.pbxproj").read_text()
        self.assertIn('Label(tr("Copy Wine log")', view)
        self.assertIn('UIPasteboard.general.string = content.text', view)
        self.assertIn('Task.detached(priority: .utility)', view)
        self.assertIn('ShareLink(item: logURL)', view)
        self.assertIn("maximumCopiedBytes = 4 * 1024 * 1024", helper)
        self.assertIn("isSymbolicLink != true", helper)
        self.assertEqual(project.count("WineLogClipboard.swift in Sources */,"), 1)

    def test_localization_does_not_duplicate_keys(self):
        source = (ROOT / "iDeck/Localization.swift").read_text()
        import re
        matches = re.findall(r'^ {8}"((?:\\.|[^"\\])+)":\s*\[', source, re.M)
        self.assertEqual(len(matches), len(set(matches)))


if __name__ == "__main__":
    unittest.main()
