"""A depot taken from another app whose file list Steam refuses is retried, then left out (2.13.3)."""
import pathlib
import unittest

SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "SwiftSteam" / "Content" / "DepotDownloader.swift").read_text()


class SharedDepotTests(unittest.TestCase):
    def test_retry_under_the_game_then_skip(self):
        self.assertIn("} catch where contentAppID != app.appID {", SRC)
        self.assertIn("manifest = try await fetchManifest(depotID: depot.depotID, appID: app.appID,", SRC)
        self.assertIn("not owned, left out", SRC)
        self.assertIn("!owned.contains(depot.depotID)", SRC)


if __name__ == "__main__":
    unittest.main()
