"""BioShock games get the older NVIDIA Direct3D 9 card (2.16.2)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REC = (ROOT / "iDeck" / "GameRecommendations.swift").read_text()
ENV = (ROOT / "iDeck" / "WindowsEnvironment.swift").read_text()


class BioShockOlderNvidia(unittest.TestCase):
    def test_recommendation(self):
        start = REC.index("static let bioshock = GameRecommendation(")
        self.assertIn("olderNvidia: true)", REC[start:start + 700])
        self.assertIn("crashBandicootNSane, bioshock, standard]", REC)
        self.assertIn('case "bioshock.exe", "bioshockhd.exe", "bioshock2.exe", "bioshock2hd.exe":', REC)
        self.assertIn("[7670, 409710, 8850, 409720]", REC)

    def test_dxmt_identity_applied_and_cleared(self):
        self.assertIn("Self.setD3D9OlderNvidia(recommendation.olderNvidia == true)", ENV)
        self.assertIn("Self.setD3D9OlderNvidia(false)", ENV)
        self.assertIn('"d3d9.customVendorId=10de", "d3d9.customDeviceId=0292"', ENV)


if __name__ == "__main__":
    unittest.main()
