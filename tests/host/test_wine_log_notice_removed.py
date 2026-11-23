"""The game session no longer shows the note about what is removed from logs (2.13.1).
The redaction itself stays."""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WineLogNoticeTests(unittest.TestCase):
    def test_notice_and_string_removed(self):
        text = "removed from copied and shared logs"
        self.assertNotIn(text, (ROOT / "iDeck" / "GameSessionView.swift").read_text())
        self.assertNotIn(text, (ROOT / "iDeck" / "Localization.swift").read_text())

    def test_logs_still_redacted(self):
        session = (ROOT / "iDeck" / "GameSessionView.swift").read_text()
        self.assertIn("RedactedLogFile(url: logURL)", session)
        self.assertIn("<redacted>", (ROOT / "iDeck" / "WineLogClipboard.swift").read_text())


if __name__ == "__main__":
    unittest.main()
