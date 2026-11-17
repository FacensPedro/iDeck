import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class DownloadCPUGateTests(unittest.TestCase):
    def test_only_devices_up_to_6gb_are_limited(self):
        src = (ROOT / "iDeck/DownloadSpeed.swift").read_text()
        self.assertIn("static let limited = ProcessInfo.processInfo.physicalMemory <= 7 << 30", src)
        self.assertIn("guard limited else { return try work() }", src)
        # Network concurrency is unchanged.
        self.assertIn("static let steamChunks = 72", src)

    def test_chunk_cpu_work_goes_through_the_gate(self):
        for path in ("iDeck/SwiftSteam/Content/DepotDownloader.swift", "iDeck/EpicDownloader.swift",
                     "iDeck/GOGContentSystem.swift"):
            self.assertIn("DownloadCPU.run", (ROOT / path).read_text(), path)


if __name__ == "__main__":
    unittest.main()
