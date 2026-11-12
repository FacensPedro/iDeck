import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / "iDeck" / name).read_text()


class RamTests(unittest.TestCase):
    def test_dxmt_low_memory_and_cache_cap(self):
        env = read("WindowsEnvironment.swift")
        self.assertIn('setenv("DXMT_MAX_FRAME_LATENCY", "1", 1)', env)
        self.assertIn('setenv("DXMT_SHADER_CACHE_MAX_MB", "128", 0)', env)

    def test_sqlite_soft_heap_limit(self):
        app = read("iDeckApp.swift")
        self.assertIn("import SQLite3", app)
        self.assertIn("sqlite3_soft_heap_limit64(32 << 20)", app)

    def test_artwork_cache_counts_decoded_pixels_and_purges(self):
        art = read("ArtworkLoader.swift")
        self.assertIn("memory.totalCostLimit = 48 << 20", art)
        self.assertIn("cost: max(pixels * 4, data.count)", art)
        self.assertIn('Notification.Name("iDeckReleaseCaches")', art)
        self.assertIn('static let releaseCachesNotification = Notification.Name("iDeckReleaseCaches")', read("ResourceGovernor.swift"))

    def test_loading_bar_and_overlay(self):
        session = read("GameSessionView.swift")
        self.assertIn("if metrics.receivedNewFrames { return nil }", session)
        self.assertIn("Frame time: ", session)


if __name__ == "__main__":
    unittest.main()
