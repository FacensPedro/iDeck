"""iDeck 3.0 foundation: session lifecycle, system libraries report, IPA name."""
import split_sources  # noqa: F401  (iDeck 3.0 split files)
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class IDeck3Foundation(unittest.TestCase):
    def test_session_lifecycle_wired(self):
        life = (ROOT / "iDeck/Application/SessionLifecycle.swift").read_text()
        for state in ("idle", "preparing", "launching", "running", "closing", "failed", "recovering"):
            self.assertIn(state, life)
        self.assertIn("SessionLifecycle.shared.report(status: status)", (ROOT / "iDeck/SystemCoordinator.swift").read_text())
        self.assertEqual((ROOT / "iDeck.xcodeproj/project.pbxproj").read_text().count("SessionLifecycle.swift"), 6)

    def test_system_libraries_report_current(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ios_system_libraries.py"), "--check"])
        self.assertEqual(result.returncode, 0)

    def test_large_files_split(self):
        for part in ("Application/SystemCoordinator+Launch.swift", "Application/SystemCoordinator+JIT.swift",
                     "Presentation/GameDetails/StoreGameDetailsView.swift", "Runtime/WindowsEnvironment+Profile.swift",
                     "Stores/EA/EALibrary+Launch.swift", "Stores/Ubisoft/UbisoftInstaller.swift"):
            path = ROOT / "iDeck" / part
            self.assertTrue(path.exists(), part)
            self.assertIn("// Split from ", path.read_text()[:300])
            self.assertEqual((ROOT / "iDeck.xcodeproj/project.pbxproj").read_text().count(path.name) >= 4, True, part)
        self.assertLess(len((ROOT / "iDeck/SystemCoordinator.swift").read_bytes().splitlines()), 800)

    def test_project_paths_are_valid_plist_strings(self):
        # An unquoted pbxproj string may hold only [A-Za-z0-9_$/:.-]; "+" made the project unreadable.
        import re
        project = (ROOT / "iDeck.xcodeproj/project.pbxproj").read_text()
        for value in re.findall(r'path = ([^";\n]+);', project):
            self.assertRegex(value, r"^[A-Za-z0-9_$/:.\-]+$")

    def test_short_ipa_name(self):
        wf = (ROOT / ".github/workflows/ios.yml").read_text()
        self.assertIn('LABEL="$(sed -E \'s/(\\.0)+$//\' <<<"$VERSION")"', wf)
        self.assertNotIn("currently 1.0.10", wf)


if __name__ == "__main__":
    unittest.main()
