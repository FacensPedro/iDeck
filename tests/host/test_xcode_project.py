import re
import unittest
from collections import Counter
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2] / "iDeck.xcodeproj" / "project.pbxproj"
OBJECT = re.compile(r"^\s*([A-F0-9]{24})\s+/\*.*?\*/\s*=", re.MULTILINE)
BUILD_FILE = re.compile(
    r"^\s*([A-F0-9]{24})\s+/\*.*?\*/\s*=\s*"
    r"\{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})\s+/\*.*?\*/;",
    re.MULTILINE,
)


class XcodeProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = PROJECT.read_text(encoding="utf-8")

    def test_object_identifiers_are_unique(self):
        ids = OBJECT.findall(self.project)
        self.assertTrue(ids, "No Xcode project objects found")
        duplicates = [key for key, count in Counter(ids).items() if count > 1]
        self.assertEqual(duplicates, [], f"Duplicate Xcode object identifiers: {duplicates}")

    def test_build_files_reference_existing_file_objects(self):
        ids = set(OBJECT.findall(self.project))
        build_files = BUILD_FILE.findall(self.project)
        self.assertTrue(build_files)
        for build_id, file_id in build_files:
            with self.subTest(build_id=build_id):
                self.assertIn(file_id, ids)

    def test_native_diagnostics_and_guest_store_are_compiled_once(self):
        marker = "333333333333333333333332 /* Sources */ = {"
        self.assertIn(marker, self.project)
        sources = self.project.split(marker, 1)[1].split("\n\t\t};", 1)[0]
        for filename in ("NativeRuntimeDiagnostics.mm", "GuestContainerStore.swift"):
            with self.subTest(filename=filename):
                # Match sources-phase entries, not the PBXBuildFile declarations.
                matching = re.findall(
                    r"^\s*([A-F0-9]{24})\s+/\* " + re.escape(filename)
                    + r" in Sources \*/,?\s*$",
                    sources,
                    re.MULTILINE,
                )
                self.assertEqual(len(matching), 1)
                build_id = matching[0]
                refs = dict(BUILD_FILE.findall(self.project))
                self.assertIn(build_id, refs)
                ref_id = refs[build_id]
                declaration = re.search(
                    r"^\s*" + ref_id + r"\s+/\* "
                    + re.escape(filename)
                    + r" \*/\s*=\s*\{isa = PBXFileReference;",
                    self.project,
                    re.MULTILINE,
                )
                self.assertIsNotNone(declaration, f"{filename} maps to the wrong source")


if __name__ == "__main__":
    unittest.main()
