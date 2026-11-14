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
        self.assertIn("static let eaRangeRequests = 20", speed)
        # 32 ranges of 4 MB: at most 128 MB held while downloading.
        self.assertIn("static let segmentBytes: Int64 = 8 << 20",
                      (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift").read_text())


if __name__ == "__main__":
    unittest.main()


class StallAndSizeTests(unittest.TestCase):
    def test_stalls_are_logged(self):
        speed = (ROOT / "iDeck/DownloadSpeed.swift").read_text()
        self.assertIn("static let stallSeconds: TimeInterval = 20", speed)
        self.assertIn('no data for \\(Int(now.timeIntervalSince(entry.time))) s at', speed)
        self.assertIn('data again after \\(Int(resumed)) s without', speed)

    def test_steam_size_counts_owned_dlc(self):
        info = (ROOT / "iDeck/SwiftSteam/Library/SteamAppInfo.swift").read_text()
        self.assertIn("func installSize(for os: String, ownedDLC: Set<UInt32> = []) -> UInt64 {", info)
        self.assertIn('let installed = installSize(for: "windows", ownedDLC: ownedDLC)', info)
        view = (ROOT / "iDeck/MainView.swift").read_text()
        self.assertIn("game.displaySizeForWindows(installedBytes: measured, ownedDLC: steamLibrary.ownedDepotIDs)", view)
        self.assertIn(".onAppear { steamLibrary.loadOwnedDepots() }", view)
