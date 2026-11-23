"""Ubisoft covers load fast, with fallbacks, and a tap never starts a download (2.13.2)."""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
UBI = (ROOT / "iDeck" / "UbisoftLibrary.swift").read_text()
VIEW = (ROOT / "iDeck" / "MainView.swift").read_text()


class CoverTests(unittest.TestCase):
    def test_lookups_run_six_at_a_time(self):
        start = UBI.index("private func findCovers() async {")
        body = UBI[start:UBI.index("private static func key(", start)]
        self.assertIn("withTaskGroup", body)
        self.assertIn("for _ in 0..<6 where !missing.isEmpty", body)
        self.assertIn("coverLookups.insert($0).inserted", body)

    def test_lookups_start_with_the_first_list(self):
        start = UBI.index("    func refresh() {")
        body = UBI[start:UBI.index("    private func publish(", start)]
        self.assertLess(body.index("Task { await self.findCovers() }"), body.index("UbisoftContentClient.signedIn()"))
        self.assertNotIn("await self.findCovers()\n        }\n    }", body)

    def test_fallback_addresses_and_search_term(self):
        self.assertIn("store_item_assets/steam/apps/\\(appID)/library_600x900.jpg", UBI)
        self.assertIn("steam/apps/\\(appID)/header.jpg", UBI)
        self.assertIn('let term = title.replacingOccurrences(of: "®", with: "")', UBI)
        self.assertIn('private static let storeKey = "ubisoft.coverAppIDs.v2"', UBI)

    def test_title_when_no_picture(self):
        self.assertIn("var fallbackTitle: String? = nil", VIEW)
        self.assertIn("} else if let fallbackTitle {", VIEW)


class InstallConfirmTests(unittest.TestCase):
    def card(self) -> str:
        start = VIEW.index("private func ubisoftCard(")
        return VIEW[start:VIEW.index("private func ubisoftDownloadBadge", start)]

    def test_tap_asks_first(self):
        card = self.card()
        self.assertIn("pendingUbisoftInstall = game", card)
        self.assertEqual(card.count("ubisoftLibrary.install(game)"), 1)   # only resuming a paused/failed one
        self.assertIn('.confirmationDialog(tr("Install %@?", pendingUbisoftInstall?.title ?? "")', VIEW)
        self.assertIn("if let game = pendingUbisoftInstall { ubisoftLibrary.install(game) }", VIEW)

    def test_failure_reason_under_the_card(self):
        self.assertIn("if case .failed(let message)? = ubisoftLibrary.downloads[game.id]?.state {", self.card())


if __name__ == "__main__":
    unittest.main()
