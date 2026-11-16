import pathlib, unittest
SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck/WineLogClipboard.swift").read_text()

class LogCompactorHex(unittest.TestCase):
    def test_hex_words_normalized(self):
        self.assertIn("static func isNumberLike(_ word: String) -> Bool", SRC)
        self.assertIn("scalars.count >= 6 && scalars.allSatisfy(isHex)", SRC)

    def test_shorter_summary(self):
        self.assertIn(".prefix(15)", SRC)

if __name__ == "__main__":
    unittest.main()
