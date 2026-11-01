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

    def test_ideck_bundle_identifiers_are_consistent(self):
        root = PROJECT.parents[1]
        expected = (
            "PRODUCT_BUNDLE_IDENTIFIER = com.ideck.ideck;",
            "PRODUCT_BUNDLE_IDENTIFIER = com.ideck.ideck.VPNExtension;",
        )
        for value in expected:
            with self.subTest(bundle=value):
                self.assertEqual(self.project.count(value), 2)
        self.assertNotIn("com.example.iDeck", self.project)
        extension_entitlements = (root / "VPNExtension/VPNExtension.entitlements").read_text(encoding="utf-8")
        self.assertIn("<string>group.com.ideck.ideck</string>", extension_entitlements)
        self.assertNotIn("group.com.example.iDeck", extension_entitlements)

    def test_ipados_26_deployment_is_consistent_for_app_and_extension(self):
        # App, VPN extension and JIT helper extension, Debug and Release, plus the project.
        self.assertEqual(self.project.count("IPHONEOS_DEPLOYMENT_TARGET = 26.0;"), 8)
        self.assertNotIn("IPHONEOS_DEPLOYMENT_TARGET = 27.0;", self.project)
        build = (PROJECT.parents[1] / "scripts/build_ipa.sh").read_text(encoding="utf-8")
        self.assertIn('[[ "$MINIMUM_OS" == "26.0" ]]', build)
        self.assertIn('[[ "${SDK_VERSION%%.*}" -ge 27 ]]', build)

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

    def test_native_performance_sources_are_compiled_once(self):
        names = (
            "FEXExecutionScheduler.cpp",
            "GuestMemoryPool.cpp",
            "RuntimePerformanceMonitor.mm",
            "MetalFrameOptimizer.mm",
            "NativePerformanceClock.cpp",
        )
        marker = "333333333333333333333332 /* Sources */ = {"
        sources = self.project.split(marker, 1)[1].split("\n\t\t};", 1)[0]
        refs = dict(BUILD_FILE.findall(self.project))
        for filename in names:
            with self.subTest(filename=filename):
                entries = re.findall(
                    r"^\s*([A-F0-9]{24})\s+/\* " + re.escape(filename)
                    + r" in Sources \*/,?\s*$",
                    sources,
                    re.MULTILINE,
                )
                self.assertEqual(len(entries), 1)
                self.assertIn(entries[0], refs)
                file_ref = refs[entries[0]]
                expected = re.compile(
                    r"^\s*" + file_ref + r"\s+/\* " + re.escape(filename)
                    + r" \*/\s*=\s*\{isa = PBXFileReference;.*path = NativeRuntime/"
                    + re.escape(filename) + r";",
                    re.MULTILINE,
                )
                self.assertRegex(self.project, expected)

    def test_performance_header_is_linked_to_swift(self):
        self.assertIn("NativePerformance.h */ = {isa = PBXFileReference;", self.project)
        root = PROJECT.parents[1]
        header = root / "iDeck" / "iDeck-Bridging-Header.h"
        self.assertIn("NativeRuntime/NativePerformance.h", header.read_text(encoding="utf-8"))

    def test_native_memory_manager_sources_are_registered(self):
        names = ("NativeMemoryManager.cpp", "NativeMemoryPressure.mm")
        marker = "333333333333333333333332 /* Sources */ = {"
        sources = self.project.split(marker, 1)[1].split("\n\t\t};", 1)[0]
        refs = dict(BUILD_FILE.findall(self.project))
        for filename in names:
            with self.subTest(filename=filename):
                entries = re.findall(
                    r"^\s*([A-F0-9]{24})\s+/\* " + re.escape(filename)
                    + r" in Sources \*/,?\s*$",
                    sources,
                    re.MULTILINE,
                )
                self.assertEqual(len(entries), 1)
                self.assertIn(entries[0], refs)
                referenced = refs[entries[0]]
                self.assertRegex(
                    self.project,
                    re.compile(
                        r"^\s*" + referenced + r"\s+/\* " + re.escape(filename)
                        + r" \*/\s*=\s*\{isa = PBXFileReference;.*path = NativeRuntime/"
                        + re.escape(filename) + r";",
                        re.MULTILINE,
                    ),
                )

    def test_native_memory_bridge_is_available_to_swift(self):
        bridge = PROJECT.parents[1] / "iDeck" / "iDeck-Bridging-Header.h"
        self.assertIn(
            'NativeRuntime/NativeMemoryManager.h',
            bridge.read_text(encoding="utf-8"),
        )

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
