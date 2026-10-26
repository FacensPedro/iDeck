import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = r"""
import Foundation
@main
struct IPAZipHostTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let unsafe = URL(fileURLWithPath: CommandLine.arguments[2])
        let symlink = URL(fileURLWithPath: CommandLine.arguments[3])
        let destination = URL(fileURLWithPath: CommandLine.arguments[4])
        let duplicate = URL(fileURLWithPath: CommandLine.arguments[5])
        let mismatched = URL(fileURLWithPath: CommandLine.arguments[6])
        let bomb = URL(fileURLWithPath: CommandLine.arguments[7])
        try ZipExtractor.extract(archive: fixture, to: destination)
        let app = destination.appendingPathComponent("Payload/Husk.app")
        precondition(FileManager.default.fileExists(atPath:
            app.appendingPathComponent("Info.plist").path))
        precondition(FileManager.default.fileExists(atPath:
            app.appendingPathComponent("Husk").path))
        for input in [unsafe, symlink, duplicate, mismatched, bomb] {
            do {
                try ZipExtractor.extract(archive: input,
                    to: destination.appendingPathComponent(UUID().uuidString))
                fatalError("Unsafe ZIP entry was accepted")
            } catch ZipError.unsafePathEntry {
                // Expected: a malformed entry must remain rejected.
            } catch ZipError.unsafePath {
                // Expected: a malformed entry must remain rejected.
            } catch ZipError.invalidArchive {
                // Expected: mismatched or duplicate archive entry.
            } catch ZipError.unsupported {
                // Expected: pathological decompression ratio.
            }
        }
        print("PASS: Husk IPA directory extracted; traversal and unsafe links rejected")
    }
}
"""


class HuskIPAExtractionTests(unittest.TestCase):
    def test_real_zip_extraction(self):
        self.assertTrue(shutil.which("xcrun"), "Runs on the macOS GitHub Actions host")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = root / "Husk.ipa"
            bad = root / "bad.ipa"
            badlink = root / "badlink.ipa"
            duplicate = root / "duplicate.ipa"
            mismatched = root / "mismatched.ipa"
            bomb = root / "bomb.ipa"
            plist = plistlib.dumps({
                "CFBundleIdentifier": "org.example.Husk",
                "CFBundleExecutable": "Husk",
            })
            with zipfile.ZipFile(good, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/", b"")
                archive.writestr("Payload/Husk.app/", b"")
                archive.writestr("Payload/Husk.app/Info.plist", plist)
                archive.writestr("Payload/Husk.app/Husk", b"test executable")
            with zipfile.ZipFile(bad, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("Payload/Husk.app/../../escape", b"unsafe")
            link = zipfile.ZipInfo("Payload/Husk.app/evil")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(badlink, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr(link, "/etc/passwd")
            with zipfile.ZipFile(duplicate, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("Payload/Husk.app/Info.plist", plist)
                archive.writestr("Payload/Husk.app/info.plist", plist)
            with zipfile.ZipFile(mismatched, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("Payload/Husk.app/Info.plist", plist)
            corrupted = bytearray(mismatched.read_bytes())
            corrupted[30:30 + len("Payload/Husk.app/Info.plist")] = (
                b"Payload/Husk.app/Evil.plist")
            mismatched.write_bytes(corrupted)
            with zipfile.ZipFile(bomb, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/Husk.app/padding.dat", b"A" * (2 * 1024 * 1024))
            source = (ROOT / "iDeck/PrefixInstaller.swift").read_text(encoding="utf-8")
            start = source.index("enum ZipError: Error {")
            actual_extractor = root / "Extractor.swift"
            actual_extractor.write_text(
                "import Foundation\nimport Compression\n\n" + source[start:],
                encoding="utf-8",
            )
            runner = root / "Runner.swift"
            runner.write_text(RUNNER, encoding="utf-8")
            binary = root / "test-ipa-extractor"
            subprocess.run(
                [
                    "xcrun", "swiftc",
                    str(ROOT / "iDeck/IPAArchivePath.swift"),
                    str(actual_extractor),
                    str(runner), "-o", str(binary),
                ], check=True, timeout=120,
            )
            subprocess.run(
                [str(binary), str(good), str(bad), str(badlink),
                 str(root / "Extracted"), str(duplicate), str(mismatched), str(bomb)],
                check=True, timeout=60,
            )


if __name__ == "__main__":
    unittest.main()
