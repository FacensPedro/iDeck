import unittest
from pathlib import Path

from support import ROOT, repo_text
SETTINGS = repo_text("iDeck/SettingsView.swift")
COORDINATOR = repo_text("iDeck/SystemCoordinator.swift")
SESSION = repo_text("iDeck/GameSessionView.swift")
STEAM = repo_text("iDeck/SteamManager.swift")
DEPOT = repo_text("iDeck/SwiftSteam/Content/DepotDownloader.swift")


class AutomaticJITAndDownloadHUDTests(unittest.TestCase):
    def test_updates_settings_hide_unnecessary_release_messages(self):
        self.assertNotIn('actionButton(title: tr("Update iDeck %@", update.latest ?? "")', SETTINGS)
        for literal in (
            'actionButton(title: tr("Open iDeck releases")',
            "No newer iDeck IPA release is available.",
            "iPadOS requires a signed IPA installation",
        ):
            self.assertNotIn(literal, SETTINGS)

    def test_overlay_defaults_off_and_never_claims_gpu_utilization(self):
        # The overlay is switched in the in-game sheet, defaulting off.
        sheet = (Path(__file__).resolve().parents[2] / "iDeck/SessionControlsSheet.swift").read_text()
        self.assertIn('@AppStorage("showGamePerformanceOverlay") private var showFPS = false', sheet)
        self.assertIn('@AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false', SESSION)
        self.assertIn('coordinator.windowsStatus == "Running"', SESSION)
        self.assertIn("metrics.receivedNewFrames", SESSION)
        self.assertIn("if showGamePerformanceOverlay &&", SESSION)
        self.assertIn('Text("FPS:', SESSION)
        self.assertIn('Text("GPU memory (Metal):', SESSION)
        self.assertIn('Text("GPU utilization: unavailable on iOS")', SESSION)
        self.assertIn("if horizontalSizeClass != .compact {", SESSION)
        self.assertIn("if collectPerformance && getrusage(", SESSION)

    def test_log_copy_is_only_offered_when_session_has_problems(self):
        self.assertIn("private var hasWineProblem: Bool", SESSION)
        self.assertIn("if hasWineProblem && wineLogURL != nil", SESSION)
        self.assertIn('status.hasPrefix("Execution Error")', SESSION)
        self.assertIn("metrics.secondsSinceLaunch >= 20 && !metrics.receivedNewFrames", SESSION)


if __name__ == "__main__":
    unittest.main()
