import re
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION = ROOT / 'iDeck/Localization.swift'
DECLARATION = 'static let table: [String: [String: String]] = ['
KEY = re.compile(r'^        "((?:[^"\\]|\\.)+)"\s*:\s*\[', re.MULTILINE)


class LocalizationDictionaryTests(unittest.TestCase):
    def test_no_duplicate_top_level_translation_keys(self):
        source = LOCALIZATION.read_text(encoding='utf-8')
        self.assertEqual(source.count(DECLARATION), 1)
        table = source.split(DECLARATION, 1)[1].rsplit('\n    ]\n}', 1)[0]
        matches = list(KEY.finditer(table))
        self.assertGreater(len(matches), 250, 'Translation key scanner missed most table entries')
        counts = Counter(match.group(1) for match in matches)
        duplicates = {key: count for key, count in counts.items() if count > 1}
        self.assertFalse(duplicates, 'Duplicate Swift dictionary literals crash the app at startup: ' + repr(duplicates))
        self.assertEqual(counts['Madeira'], 1)


if __name__ == '__main__':
    unittest.main()
