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

    def test_every_translation_is_used(self):
        source = LOCALIZATION.read_text(encoding='utf-8')
        table = source.split(DECLARATION, 1)[1].rsplit('\n    ]\n}', 1)[0]
        code = ''.join(path.read_text(encoding='utf-8') for path in (ROOT / 'iDeck').rglob('*.swift')
                       if path.name != 'Localization.swift')
        unused = [m.group(1) for m in KEY.finditer(table)
                  if '"' + m.group(1) + '"' not in code and m.group(1) not in ('Madeira', 'System default')]
        self.assertFalse(unused, 'Translations no Swift file uses: ' + repr(unused[:20]))


if __name__ == '__main__':
    unittest.main()
