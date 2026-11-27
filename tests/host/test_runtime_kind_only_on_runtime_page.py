""""Madeira-native" appears only as the IPA runtime on the runtime page (2.13.1)."""
from __future__ import annotations

import split_sources  # noqa: F401  (iDeck 3.0 split files)
import pathlib
import unittest

SETTINGS = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "SettingsView.swift").read_text()


class RuntimeKindTests(unittest.TestCase):
    def test_windows_runtime_row_has_no_value(self):
        self.assertIn('SettingsRow(icon: "cpu.fill", color: .green, title: tr("Windows runtime"))', SETTINGS)

    def test_shown_once_as_ipa_runtime(self):
        self.assertEqual(SETTINGS.count('"Madeira-native"'), 1)
        at = SETTINGS.index('"Madeira-native"')
        self.assertLess(SETTINGS.rindex('LabeledContent(tr("IPA runtime"))', 0, at), at)


if __name__ == "__main__":
    unittest.main()
