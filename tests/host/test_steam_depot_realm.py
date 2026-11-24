import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INFO = (ROOT / "iDeck/SwiftSteam/Library/SteamAppInfo.swift").read_text()
FETCH = (ROOT / "iDeck/SwiftSteam/Library/SteamLibraryFetcher.swift").read_text()


class SteamDepotRealmTests(unittest.TestCase):
    def test_realm_is_parsed(self):
        self.assertIn('di.realm = config["realm"] as? String ?? ""', INFO)

    def test_steam_china_depots_are_left_out_of_install_and_size(self):
        self.assertIn('realm.caseInsensitiveCompare("steamglobal") == .orderedSame', INFO)
        self.assertIn("d.manifestID(branch) != nil && !d.lowViolence && d.isGlobalRealm", INFO)
        self.assertIn("d.supports(os: os) && !d.lowViolence && d.isGlobalRealm", INFO)
        self.assertIn('if !d.isGlobalRealm { return "realm" }', INFO)
        self.assertIn("!d.lowViolence && d.isGlobalRealm", FETCH)

    def test_optional_dlc_depots_need_the_dlc(self):
        self.assertIn('config["optionaldlc"]', INFO)
        self.assertIn("di.dlcAppID = optional", INFO)


if __name__ == "__main__":
    unittest.main()
