"""The Ubisoft sign-in stays saved until Sign out, as for the other stores (2.13.1)."""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SETTINGS = (ROOT / "iDeck" / "SettingsView.swift").read_text()
SOURCES = {p: p.read_text() for p in (ROOT / "iDeck").rglob("*.swift")}


class UbisoftSavedLoginTests(unittest.TestCase):
    def test_only_sign_out_clears_the_session(self):
        calls = [(p.name, m.start()) for p, text in SOURCES.items()
                 for m in re.finditer(r"UbisoftSavedSession\.clear\(\)", text)]
        self.assertEqual(len(calls), 1, calls)
        sign_out = SETTINGS.index('Button(tr("Sign out"), role: .destructive) {\n                        if UbisoftSavedSession.clear()')
        self.assertGreater(sign_out, 0)

    def test_failed_renewal_keeps_the_account(self):
        start = SETTINGS.index("@MainActor private func restoreUbisoftSession() async {")
        body = SETTINGS[start:SETTINGS.index("private var eaPage", start)]
        self.assertNotIn("clear()", body)
        self.assertIn("await UbisoftSavedSession.current()", body)
        self.assertIn("ubisoftSessionExpired = true", body)

    def test_expired_session_offers_sign_in_again(self):
        self.assertIn('Button(tr("Sign in again")) { ubisoftLoginPresented = true }', SETTINGS)
        self.assertIn("onDismiss: { Task { await restoreUbisoftSession() } }", SETTINGS)
        localization = (ROOT / "iDeck" / "Localization.swift").read_text()
        self.assertIn('"Sign in again": ["pt": "Entrar de novo"', localization)

    def test_session_is_in_the_keychain(self):
        self.assertIn('kSecAttrService as String: "iDeck.Ubisoft"', SETTINGS)
        self.assertIn("SecItemAdd(Self.query.merging(values)", SETTINGS)


if __name__ == "__main__":
    unittest.main()
