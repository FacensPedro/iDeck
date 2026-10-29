import importlib.util
import os
import pathlib
import stat
import tempfile
import unittest
from zipfile import ZipFile, ZIP_STORED

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_ipa", ROOT / "scripts/package_ipa.py")
package_ipa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_ipa)


class FastIPARegressionTests(unittest.TestCase):
    def test_streams_valid_payload_without_copy_and_preserves_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app = root / "build/Build/Products/Release-iphoneos/iDeck.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(b"plist")
            executable = app / "iDeck"
            executable.write_bytes(b"\xcf\xfa\xed\xfe" * 5000)
            executable.chmod(0o755)
            framework = app / "Frameworks"
            framework.mkdir()
            (framework / "Engine").write_bytes(b"valid framework binary")
            (framework / "Shortcut").symlink_to("Engine")
            (app / "Assets.car").write_bytes(b"ALREADYCOMPRESSED")
            (app / "resources").mkdir()
            (app / "resources/big.txt").write_text("text content" * 500)
            archive = root / "iDeck.ipa"
            package_ipa.build_ipa(app, archive)

            self.assertTrue(archive.exists())
            self.assertFalse((root / "Payload").exists())
            with ZipFile(archive) as ipa:
                names = ipa.namelist()
                self.assertEqual(len(names), len(set(names)))
                prefix = "Payload/iDeck.app/"
                for name in (
                    "Payload/", prefix, prefix + "Info.plist", prefix + "iDeck",
                    prefix + "Frameworks/Engine", prefix + "Frameworks/Shortcut",
                    prefix + "Assets.car", prefix + "resources/big.txt",
                ):
                    self.assertIn(name, names)
                self.assertIsNone(ipa.testzip())
                self.assertEqual(ipa.read(prefix + "Info.plist"), b"plist")
                self.assertEqual(ipa.read(prefix + "Frameworks/Shortcut"), b"Engine")
                executable_bits = ipa.getinfo(prefix + "iDeck").external_attr >> 16
                self.assertTrue(executable_bits & stat.S_IXUSR)
                link_bits = ipa.getinfo(prefix + "Frameworks/Shortcut").external_attr >> 16
                self.assertTrue(stat.S_ISLNK(link_bits))
                self.assertEqual(ipa.getinfo(prefix + "Assets.car").compress_type, ZIP_STORED)

    def test_rejects_invalid_app_and_cleans_up_partial_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with self.assertRaisesRegex(ValueError, "Info.plist"):
                package_ipa.build_ipa(root, root / "iDeck.ipa")
            self.assertFalse((root / "iDeck.ipa.part").exists())

    def test_build_script_avoids_deleting_xcode_intermediates(self):
        script = (ROOT / "scripts/build_ipa.sh").read_text()
        self.assertNotIn('xcodebuild clean build', script)
        self.assertNotIn('rm -rf "$BUILD_DIR/Build"', script)
        self.assertIn('xcodebuild build', script)
        self.assertIn('ditto "$COMPILED_APP" "$APP"', script)
        self.assertIn('python3 scripts/package_ipa.py --app "$APP" --output iDeck.ipa', script)
        self.assertNotIn('cp -R "$APP" Payload/', script)


if __name__ == "__main__":
    unittest.main()
