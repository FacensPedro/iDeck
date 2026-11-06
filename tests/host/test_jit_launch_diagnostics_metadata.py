import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
BUGS = (ROOT / "iDeck/BugReportView.swift").read_text(encoding="utf-8")
SERVICE = (ROOT / "iDeck/IRelayDeviceService.swift").read_text(encoding="utf-8")
NOTES = (ROOT / "RELEASE_NOTES.md").read_text(encoding="utf-8")

class LauncherJITAndDiagnosticsTests(unittest.TestCase):
    def test_nonsteam_launchers_use_existing_auto_jit_handshake(self):
        self.assertNotIn("guard requireJIT() else { return }", MAIN)
        self.assertNotIn("private func requireJIT()", MAIN)
        self.assertIn("StikJITHelper.enableJIT", COORD)
        self.assertIn("guard self.ensureJITForGameLaunch() else { return }", COORD)
        self.assertIn("coordinator.launchWindowsExecutable(at: executable, profile: profile)", MAIN)
        self.assertIn("coordinator.launchWindowsExecutable(at: game.executable, profile: profile)", MAIN)

    def test_gog_installer_uses_real_pe_architecture(self):
        self.assertIn("WindowsEnvironment.isPE32WindowsExecutable(destination)", COORD)
        self.assertIn("coordinator.launchWindowsExecutable(at: setup, profile: profile)", MAIN)

    def test_bug_reports_contain_game_launcher_and_real_device(self):
        for key in ("diagnostics.lastGame", "diagnostics.lastLauncher"):
            self.assertIn(key, COORD)
            self.assertIn(key, BUGS)
        for launcher in ("Steam", "Epic Games", "GOG", ".exe"):
            self.assertIn('"' + launcher + '"', COORD)
        for item in ("iPhone15,4", "iPad16,1", "activeProcessorCount", "sysctlbyname"):
            self.assertIn(item, BUGS)
        self.assertIn("BugReportModel.hardwareSummary", SERVICE)
        self.assertIn("BugReportModel.gameContext", SERVICE)

    def test_clear_logs_is_blocked_during_downloads(self):
        self.assertIn("downloadsOrTransfersActive", BUGS)
        self.assertIn("downloadProgress.keys.contains", BUGS)
        self.assertIn("showClearConfirmation", BUGS)
        self.assertIn("BugReportModel.downloadsOrTransfersActive", SERVICE)
        self.assertIn("return .error(409,", SERVICE)

    def test_clean_release_and_centered_jit_status(self):
        top = MAIN.split("private var topBar: some View")[1].split("private enum MixedLibraryEntry")[0]
        self.assertIn('Text("iDeck")', top)
        self.assertNotIn('Image("IDeckLogo")', top)
        self.assertIn(".frame(maxWidth: .infinity)", top)
        self.assertNotIn("Bendy", NOTES)
        self.assertNotIn("Bendy and the Ink Machine", NOTES)

if __name__ == "__main__":
    unittest.main()
