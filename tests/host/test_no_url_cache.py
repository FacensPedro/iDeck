import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class NoURLCacheTests(unittest.TestCase):
    def test_shared_cache_disabled_at_launch(self):
        self.assertIn("URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)",
                      (ROOT / "iDeck/iDeckApp.swift").read_text())

    def test_gog_downloads_bypass_the_cache(self):
        gog = (ROOT / "iDeck/GOGLibrary.swift").read_text()
        block = gog[gog.index("static let session: URLSession = {"):][:600]
        self.assertIn("config.urlCache = nil", block)

    def test_restart_gate_compiles_against_optional_status(self):
        coord = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn("if let ntstatus, ntstatus != 0 { Self.restartReason", coord)
        self.assertNotIn("let free = ResourceGovernor.availableMiB()", coord)


if __name__ == "__main__":
    unittest.main()
