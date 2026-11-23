"""No closing message next to the session's settings button (2.13.3)."""
import pathlib
import unittest

SESSION = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "GameSessionView.swift").read_text()


class ClosingTextTests(unittest.TestCase):
    def test_only_the_closing_box_remains(self):
        self.assertEqual(SESSION.count('Text(tr("Closing Wine and wineserver..."))'), 1)
        self.assertIn("if !coordinator.isClosingWindowsSession && !metrics.receivedNewFrames && metalFXTurnedOff {", SESSION)


if __name__ == "__main__":
    unittest.main()
