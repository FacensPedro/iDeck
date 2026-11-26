"""iDeck Auto DLL Manager (2.16.2)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
M = (ROOT / "iDeck" / "AutoDLLManager.swift").read_text()


class AutoDLLManager(unittest.TestCase):
    def test_official_source_and_trust(self):
        self.assertIn("url: NativeD3DX.redistURL", M)
        self.assertIn("VisualCRuntimeBootstrap.isTrustedDownloadURL(final)", M)

    def test_cache_verify_rollback(self):
        self.assertIn('appendingPathComponent("iDeck/DLL Cache"', M)
        self.assertIn("DependencyCheck.check(program: program", M)
        self.assertIn("static func rollbackAll() -> Int", M)

    def test_wired_into_launch_and_failure(self):
        self.assertIn("AutoDLLManager.resolve(check, program: binary", (ROOT / "iDeck/WindowsEnvironment.swift").read_text())
        self.assertIn("AutoDLLManager.notePending(dlls, program: program)", (ROOT / "iDeck/SystemCoordinator.swift").read_text())
        self.assertIn("AutoDLLManager.rollbackAll()", (ROOT / "iDeck/SettingsView.swift").read_text())
        self.assertEqual((ROOT / "iDeck.xcodeproj/project.pbxproj").read_text().count("AutoDLLManager.swift"), 6)


if __name__ == "__main__":
    unittest.main()
