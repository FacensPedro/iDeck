import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "iDeck/EALibrary.swift").read_text()


class EALicenceEveryLaunchTests(unittest.TestCase):
    def test_renewed_at_every_launch_and_kept_only_on_failure(self):
        block = EA[EA.index("let stale = EALicense.needsRenewal"):EA.index("Self.writeRegistry(record)")]
        self.assertLess(block.index("try await EALicense.renew("), block.index("licence kept (renewal failed)"))
        # As a GOG game without GOG Galaxy, a failed renewal no longer stops the launch.
        self.assertNotIn("if stale { throw error }", block)
        self.assertIn("the game's activation decides", block)
        self.assertNotIn("if EALicense.needsRenewal(", EA)
        self.assertNotIn('throw EAAPIError.license("the game\'s content id is unknown")', EA)


if __name__ == "__main__":
    unittest.main()
