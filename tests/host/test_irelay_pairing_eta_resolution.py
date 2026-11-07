import unittest

from support import repo_text

ETA = repo_text("iDeck/DownloadSpeed.swift")
MODELS = repo_text("iDeck/WindowsLibraryModels.swift")
SERVICE = repo_text("iDeck/IRelayDeviceService.swift")
TUNNEL = repo_text("iDeck/IRelayClient.swift")
PLIST = repo_text("iDeck/Info.plist")
VIEW = repo_text("iDeck/MainView.swift")


class PairingETAResolutionTests(unittest.TestCase):
    def test_eta_label_interpolates_values(self):
        label = ETA.split("static func label", 1)[1]
        self.assertNotIn('"(seconds', label)
        self.assertNotIn(' (seconds', label)
        self.assertIn('"\\(seconds / 60)m"', label)
        self.assertIn('"\\(seconds / 3_600)h \\(seconds % 3_600 / 60)m"', label)

    def test_default_resolution_is_720p_and_old_default_migrates(self):
        self.assertIn('var resolution: String = "1280x720"', MODELS)
        self.assertNotIn('resolution: String = "960x540"', MODELS)
        self.assertIn('savedDefaults == nil && savedResolution == "960x540" ? "1280x720"', MODELS)
        self.assertIn("resolutionDefaults", MODELS.split("private enum CodingKeys", 1)[1].split("}", 1)[0])
        self.assertIn("width ?? 1280", repo_text("iDeck/RuntimeConfiguration.swift"))

    def test_pairing_triggers_local_network_access_and_reports_refusals(self):
        self.assertIn('NWBrowser(for: .bonjour(type: "_ideck._tcp", domain: nil)', SERVICE)
        self.assertIn("<string>_ideck._tcp</string>", PLIST)
        self.assertIn('"deviceID": IRelayPairing.deviceID', SERVICE)
        self.assertIn("IRelayPairing.isLocked(peer)", SERVICE)
        self.assertIn("failures.removeAll()", SERVICE)
        self.assertIn('Data("IRELAY-DENIED\\n".utf8)', TUNNEL)

    def test_store_list_has_ea_and_ubisoft_icons(self):
        self.assertIn("ForEach([GameStore.steam, .gog, .epic, .ea, .ubisoft]", VIEW)
        self.assertIn('case .ea: return "StoreBadgeEA"', VIEW)
        self.assertIn('case .ubisoft: return "StoreBadgeUbisoft"', VIEW)


if __name__ == "__main__":
    unittest.main()
