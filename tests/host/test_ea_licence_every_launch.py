import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "iDeck/EALibrary.swift").read_text()


class EALicenceEveryLaunchTests(unittest.TestCase):
    def test_renewed_at_every_launch_and_kept_only_on_failure(self):
        block = EA[EA.index("let stale = EALicense.needsRenewal"):EA.index("Self.writeRegistry(record)")]
        self.assertLess(block.index("try await EALicense.renew("), block.index("licence kept (renewal failed)"))
        self.assertIn("if stale { throw error }", block)
        self.assertNotIn("if EALicense.needsRenewal(", EA)


if __name__ == "__main__":
    unittest.main()
