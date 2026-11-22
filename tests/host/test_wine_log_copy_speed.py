import pathlib, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = (ROOT / "iDeck/WineLogClipboard.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()

class WineLogCopySpeed(unittest.TestCase):
    def test_copy_compacts_bytes_not_strings(self):
        self.assertIn("try PrivacyRedactor.redact(LogCompactor.compactedData(raw)).write(to: destination", SRC)
        self.assertNotIn("LogCompactor.compact(String(decoding: raw", SRC)
        self.assertIn("static func compactedData(_ data: Data) -> Data", SRC)
        self.assertIn("static func normalizedKey<C: Collection>", SRC)

    def test_rotation_compresses_bytes(self):
        self.assertIn("LogCompactor.writeCompressed(data: data, to: previous)", COORD)

if __name__ == "__main__":
    unittest.main()
