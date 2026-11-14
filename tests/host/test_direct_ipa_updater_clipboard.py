import unittest
from pathlib import Path

from support import ROOT, repo_text
class DirectIPAUpdaterAndClipboardTests(unittest.TestCase):
    def test_ipa_is_uploaded_as_a_raw_file_not_a_second_zip(self):
        workflow = repo_text(".github/workflows/ios.yml")
        segment = workflow.split("      - name: Upload IPA directly (no outer ZIP)", 1)[1].split("      - name:", 1)[0]
        self.assertIn("uses: actions/upload-artifact@v7", segment)
        self.assertIn("path: iDeck-*.ipa", segment)
        self.assertIn("Resolve versioned IPA artifact from project version", workflow)
        self.assertIn("steps.ipa_name.outputs.name", workflow)
        self.assertIn("Prepare versioned IPA filename", workflow)
        self.assertIn("Restore canonical IPA name for integrity verification", workflow)
        self.assertIn("archive: false", segment)
        self.assertIn("id: ipa_artifact", segment)
        self.assertIn("steps.ipa_artifact.outputs.artifact-url", workflow)
        self.assertIn("gh release upload", workflow)
        self.assertIn("gh release create", workflow)

    def test_updater_checks_verified_github_ipa_releases(self):
        source = repo_text("iDeck/UpdateChecker.swift")
        settings = repo_text("iDeck/SettingsView.swift")
        self.assertIn("ipa.path.hasPrefix(\"/FacensPedro/iDeck/releases/download/\")", source)
        self.assertIn('parts.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]', source)
        self.assertIn('["sidestore", "altstore"]', source)
        self.assertIn("func openIDeckReleases()", source)
        self.assertNotIn('actionButton(title: tr("Open iDeck releases")', settings)
        self.assertNotIn('No newer iDeck IPA release is available.', settings)
        self.assertNotIn('iPadOS requires a signed IPA installation', settings)
        self.assertNotIn('actionButton(title: tr("Update iDeck %@", update.latest ?? "")', settings)
        self.assertIn("func installIDeckUpdate()", source)

    def test_copy_log_is_one_tap_and_bounded(self):
        view = repo_text("iDeck/GameSessionView.swift")
        helper = repo_text("iDeck/WineLogClipboard.swift")
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertIn('Label(tr("Copy Wine log")', view)
        self.assertIn('WineLogClipboard.copyFile(from: url)', view)
        self.assertIn('Task.detached(priority: .utility)', helper)
        self.assertIn('registerFileRepresentation', helper)
        self.assertIn('Wine-log.txt', helper)
        self.assertIn('ShareLink(item: logURL)', view)
        self.assertIn("maximumCopiedBytes = 4 * 1024 * 1024", helper)
        self.assertIn("isSymbolicLink != true", helper)
        self.assertEqual(project.count("WineLogClipboard.swift in Sources */,"), 1)

    def test_localization_does_not_duplicate_keys(self):
        source = repo_text("iDeck/Localization.swift")
        import re
        matches = re.findall(r'^ {8}"((?:\\.|[^"\\])+)":\s*\[', source, re.M)
        self.assertEqual(len(matches), len(set(matches)))


if __name__ == "__main__":
    unittest.main()
