import split_sources  # noqa: F401  (iDeck 3.0 split files)
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()


class SessionTempCleanupTests(unittest.TestCase):
    def test_temp_folders_cleaned_after_session_only_before_its_start(self):
        self.assertIn("Self.cleanWindowsTemp(before: sessionTempCutoff)", COORD)
        self.assertIn("sessionTempCutoff = Date()", COORD)
        self.assertIn("guard let modified = values?.contentModificationDate, modified < cutoff else { continue }", COORD)
        self.assertIn('drive.appendingPathComponent("windows/temp")', COORD)
        self.assertIn('appendingPathComponent("AppData/Local/Temp")', COORD)

    def test_never_while_wine_runs_or_outside_the_prefix(self):
        self.assertIn("guard !ideck_wineprocess_running() else { return }", COORD)
        self.assertIn('guard resolved.path.hasPrefix(drive.resolvingSymlinksInPath().path + "/")', COORD)


class HangNoticeTests(unittest.TestCase):
    def test_stall_after_first_frame_is_shown_and_logged(self):
        self.assertIn("static let stallSeconds = 20", SESSION)
        self.assertIn("if receivedNewFrames, let last = lastFrameChangeAt {", SESSION)
        self.assertIn('"[hang] no new frame for', SESSION)
        self.assertIn('tr("No new image for %d s: the game may be frozen. Wait, or close it with X.", metrics.stalledSeconds)', SESSION)


if __name__ == "__main__":
    unittest.main()
