"""Download speed and problems reach the log Bugs & logs reads."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DownloadLogTests(unittest.TestCase):
    def test_every_store_logs_speed_and_outcome(self):
        speed = (ROOT / "iDeck/DownloadSpeed.swift").read_text()
        self.assertIn("enum DownloadLog {", speed)
        self.assertIn("static let interval: TimeInterval = 15", speed)
        background = (ROOT / "iDeck/BackgroundDownloads.swift").read_text()
        self.assertIn("DownloadLog.progress(store: source, name: currentName, done: done, total: total)", background)
        self.assertIn('DownloadLog.ended(store: source, name: name, outcome: "failed: " + reason)', background)
        ea = (ROOT / "iDeck/EALibrary.swift").read_text()
        self.assertIn('DownloadLog.progress(store: "EA app", name: title,', ea)
        self.assertIn('DownloadLog.ended(store: "EA app", name: title, outcome: "finished")', ea)
        self.assertIn('outcome: "failed: " + error.localizedDescription)', ea)

    def test_bug_report_keeps_the_lines(self):
        self.assertIn('"[download]", "[ea-download]"', (ROOT / "iDeck/BugReportView.swift").read_text())

    def test_ea_range_memory_stays_bounded(self):
        speed = (ROOT / "iDeck/DownloadSpeed.swift").read_text()
        self.assertIn("static let eaRangeRequests = 32", speed)
        # 32 ranges of 4 MB: at most 128 MB held while downloading.
        self.assertIn("static let segmentBytes: Int64 = 4 << 20",
                      (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift").read_text())


if __name__ == "__main__":
    unittest.main()
