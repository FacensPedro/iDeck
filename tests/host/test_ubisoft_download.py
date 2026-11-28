import unittest

from support import repo_text

DL = repo_text("iDeck/UbisoftDownloader.swift")
LIB = repo_text("iDeck/UbisoftLibrary.swift")
VIEW = repo_text("iDeck/MainView.swift")
PROJECT = repo_text("iDeck.xcodeproj/project.pbxproj")


def slice_char(hex_hash: str) -> str:
    """ubisoft-demux's fileHashToPathChar, the reference for UbisoftManifest.slicePath."""
    alphabet = "0123456789abcdefghijklmnopqrstuv"
    value = int(hex_hash[1] + hex_hash[0], 16)
    return alphabet[value // 16 + (0 if value % 2 == 0 else 16)]


class UbisoftDemuxProtocolTests(unittest.TestCase):
    def test_demux_host_and_message_numbers(self):
        self.assertIn('static let host = "dmx.upc.ubisoft.com"', DL)
        self.assertIn('auth.string(2, "uplay_pc")', DL)          # AuthenticateReq.client_id
        self.assertIn("token.string(3, ticket)", DL)              # Token.ubi_ticket
        self.assertIn("req.data(3, open.bytes)", DL)              # Req.open_connection_req
        self.assertIn('openConnection("ownership_service")', DL)
        self.assertIn('openConnection("download_service")', DL)
        self.assertIn("req.data(28, token.bytes)", DL)            # ownership_token_req
        self.assertIn("tokenRsp.data(27)", DL)                     # ownership_token_rsp
        self.assertIn("initialize.string(5, token)", DL)          # download InitializeReq.ownership_token

    def test_manifest_layout(self):
        self.assertIn("for skip in [356, 0]", DL)
        self.assertIn("root.uint(21)", DL)                         # compressionMethod
        self.assertIn("where number == 4", DL)                     # chunks
        self.assertIn("slice.data(3)", DL)                         # Slice.downloadSha1

    def test_slice_path_matches_the_reference(self):
        self.assertIn("let index = Int(value / 16) + (value % 2 == 0 ? 0 : 16)", DL)
        self.assertIn("String([chars[1], chars[0]])", DL)
        self.assertEqual(slice_char("A1B2"), "1")
        self.assertEqual(slice_char("0F00"), "f")
        self.assertEqual(slice_char("1A00"), "q")

    def test_no_zlib_in_swift(self):
        self.assertNotIn("import zlib", DL)
        self.assertIn("ideck_zip_inflate_raw", DL)
        self.assertIn("zstd_safe_decompress", DL)


class UbisoftInstallFlowTests(unittest.TestCase):
    def test_page_installs_instead_of_pointing_to_settings(self):
        # 2.13.3: the card opens the game's page, which installs, pauses and stops.
        start = VIEW.index("struct UbisoftGameDetailsSheet: View {")
        page = VIEW[start:VIEW.index("\n}\n", start)]
        self.assertIn("onInstall: { StoreProviders.of(.ubisoft).install(game.id, prefix: nil) }", page)
        self.assertIn("onPause: { StoreProviders.of(.ubisoft).pause(game.id) }", page)
        self.assertIn("onStop: { StoreProviders.of(.ubisoft).cancel(game.id) }", page)
        card = VIEW[VIEW.index("func ubisoftCard("):VIEW.index("\n    }\n", VIEW.index("func ubisoftCard("))]
        self.assertIn("let open = { selectedUbisoftGame = game }", card)
        self.assertNotIn("Install it in Ubisoft Connect", card)

    def test_install_records_and_registry(self):
        self.assertIn('static let installRoot = "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games"', LIB)
        self.assertIn('"Software\\\\Ubisoft\\\\Launcher\\\\Installs\\\\\\(productID)"', LIB)
        self.assertIn("for (id, relative) in installedByIDeck where folders[id] == nil", LIB)
        self.assertIn("StoreClient.installWithoutWine(.ubisoft)", LIB)

    def test_file_is_in_the_target(self):
        self.assertEqual(PROJECT.count("UbisoftDownloader.swift"), 6)


if __name__ == "__main__":
    unittest.main()
