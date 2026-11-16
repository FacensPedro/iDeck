import pathlib, unittest
RECS = (pathlib.Path(__file__).resolve().parents[2] / "iDeck/GameRecommendations.swift").read_text()

class BlackFlagWined3d(unittest.TestCase):
    def test_recommendation_uses_wined3d(self):
        block = RECS.split("static let blackFlag = GameRecommendation(", 1)[1].split("static let all", 1)[0]
        self.assertIn("d3d9 = wined3d", block)

    def test_matched(self):
        self.assertIn("blackFlagAppID = 242050", RECS)
        self.assertIn('case "ac4bfsp.exe":', RECS)
        self.assertIn("blackFlag, crashBandicootNSane, standard]", RECS)

if __name__ == "__main__":
    unittest.main()
