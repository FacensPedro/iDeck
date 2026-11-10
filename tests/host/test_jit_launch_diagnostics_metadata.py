import unittest
from pathlib import Path

from support import ROOT, repo_text
MAIN = repo_text("iDeck/MainView.swift")
COORD = repo_text("iDeck/SystemCoordinator.swift")
BUGS = repo_text("iDeck/BugReportView.swift")
NOTES = repo_text("RELEASE_NOTES.md")

class LauncherJITAndDiagnosticsTests(unittest.TestCase):
    def test_nonsteam_launchers_use_existing_auto_jit_handshake(self):
        self.assertNotIn("guard requireJIT() else { return }", MAIN)
        self.assertNotIn("private func requireJIT()", MAIN)
        self.assertIn("StikJITHelper.enableJIT", COORD)
        self.assertIn("guard self.ensureJITForGameLaunch() else { return }", COORD)
        self.assertIn("coordinator.launchWindowsProgram(at: executable, profile: profile, detectInstaller: false)", MAIN)
        self.assertIn("coordinator.launchWindowsProgram(at: game.executable, profile: profile, detectInstaller: false)", MAIN)

    def test_gog_installer_uses_real_pe_architecture(self):
        self.assertIn("WindowsEnvironment.isPE32WindowsExecutable(destination)", COORD)
        self.assertNotIn("coordinator.launchWindowsExecutable(at: setup, profile: profile)", MAIN)

    def test_bug_reports_contain_game_launcher_and_real_device(self):
        for key in ("diagnostics.lastGame", "diagnostics.lastLauncher"):
            self.assertIn(key, COORD)
            self.assertIn(key, BUGS)
        for launcher in ("Steam", "Epic Games", "GOG", ".exe"):
            self.assertIn('"' + launcher + '"', COORD)
        for item in ("iPhone15,4", "iPad16,1", "activeProcessorCount", "sysctlbyname"):
            self.assertIn(item, BUGS)

    def test_clear_logs_is_blocked_during_downloads(self):
        self.assertIn("downloadsOrTransfersActive", BUGS)
        self.assertIn("downloadProgress.keys.contains", BUGS)
        self.assertIn("showClearConfirmation", BUGS)

    def test_clean_release_and_centered_jit_status(self):
        top = MAIN.split("private var topBar: some View")[1].split("private enum MixedLibraryEntry")[0]
        self.assertIn('Text("iDeck")', top)
        self.assertNotIn('Image("IDeckLogo")', top)
        self.assertIn(".frame(maxWidth: .infinity)", top)
        self.assertNotIn("Bendy", NOTES)
        self.assertNotIn("Bendy and the Ink Machine", NOTES)

if __name__ == "__main__":
    unittest.main()
