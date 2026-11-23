"""The Ubisoft library loads after signing in (2.13.1)."""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIBRARY = (ROOT / "iDeck" / "UbisoftLibrary.swift").read_text()
DOWNLOADER = (ROOT / "iDeck" / "UbisoftDownloader.swift").read_text()
MAIN = (ROOT / "iDeck" / "MainView.swift").read_text()
SETTINGS = (ROOT / "iDeck" / "SettingsView.swift").read_text()


def refresh_body() -> str:
    start = LIBRARY.index("    func refresh() {")
    return LIBRARY[start:LIBRARY.index("    private func publish(", start)]


class UbisoftLibraryRefreshTests(unittest.TestCase):
    def test_titles_shown_before_the_ownership_service(self):
        body = refresh_body()
        first_publish = body.index("self.publish(installed: installed, owned: owned)")
        self.assertLess(body.index("self.refreshing = false"), body.index("UbisoftContentClient.signedIn()"))
        self.assertLess(first_publish, body.index("UbisoftContentClient.signedIn()"))

    def test_expired_session_is_renewed(self):
        self.assertIn("await UbisoftSavedSession.current()", refresh_body())

    def test_refresh_during_refresh_runs_again(self):
        body = refresh_body()
        self.assertIn("guard task == nil else { refreshAgain = true; return }", body)
        self.assertIn("if self.refreshAgain {", body)

    def test_store_page_follows_sign_in(self):
        self.assertIn("@Published private(set) var signedIn", LIBRARY)
        self.assertIn("private var ubisoftSignedIn: Bool { ubisoftLibrary.signedIn }", MAIN)
        self.assertNotIn("ubisoftSignedIn = ", MAIN)
        self.assertIn("UbisoftLibrary.shared.refresh()   // the store page lists the account's games now", SETTINGS)
        self.assertIn('ubisoftAccountName = ""; UbisoftLibrary.shared.refresh()', SETTINGS)

    def test_demux_connection_has_a_deadline(self):
        self.assertIn('continuation.resume(throwing: UbisoftDemuxError.timeout("connection, \\(reason)"))', DOWNLOADER)

    def test_no_safari_sign_in(self):
        self.assertNotIn("account.ubisoft.com", SETTINGS)
        self.assertNotIn('Link(tr("Ubisoft account")', SETTINGS)


if __name__ == "__main__":
    unittest.main()
