import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class SteamNativeMigrationTests(unittest.TestCase):
    def test_c_sources_are_in_real_app_build(self):
        project = read("iDeck.xcodeproj/project.pbxproj")
        for name in ("SteamNativeCore.c", "WineLogTriage.c"):
            with self.subTest(name=name):
                self.assertEqual(project.count(f"/* {name} in Sources */,"), 1)
                self.assertIn(f"/* {name} */ = {{isa = PBXFileReference;", project)
        bridge = read("iDeck/iDeck-Bridging-Header.h")
        self.assertIn('#import "SteamNativeCore.h"', bridge)
        self.assertIn('#import "NativeRuntime/WineLogTriage.h"', bridge)

    def test_steam_aes_and_checksum_move_out_of_swift(self):
        aes = read("iDeck/SteamContentDecryptor.swift")
        native = read("iDeck/SteamNativeCore.c")
        self.assertIn("ideck_steam_decrypt_chunk(", aes)
        self.assertNotIn("CCCrypt(", aes)
        self.assertIn("kCCOptionECBMode", native)
        self.assertIn("kCCOptionPKCS7Padding", native)
        self.assertIn("memset(iv, 0", native)
        self.assertIn("output_capacity < input_length - 16 + 16", native)

    def test_existing_file_hashing_moves_to_bounded_native_buffer(self):
        reader = read("iDeck/SteamExistingChunkVerifier.swift")
        native = read("iDeck/SteamNativeCore.c")
        self.assertIn("ideck_steam_verifier_open", reader)
        self.assertIn("ideck_steam_verifier_check", reader)
        self.assertIn("try Task.checkCancellation()", reader)
        self.assertNotIn("CC_SHA1(", reader)
        self.assertNotIn("pread(", reader)
        self.assertIn("IDECK_STEAM_READ_WINDOW = 4 * 1024 * 1024", native)
        self.assertIn("O_NOFOLLOW", native)
        self.assertIn("reader->window_length", native)

    def test_steam_cloud_streams_in_c_and_depot_sha_hex_avoids_formatter(self):
        cloud = read("iDeck/SteamCloud.swift")
        manifest = read("iDeck/SteamDepotManifest.swift")
        self.assertIn("ideck_steam_sha1_file(", cloud)
        self.assertIn("ideck_steam_hex_encode(", manifest)
        self.assertIn("guard sha.count == 20", manifest)
        self.assertNotIn('sha.map { String(format: "%02x", $0) }', manifest)

    def test_madeira_style_diagnostics_do_not_parse_large_logs_on_refresh(self):
        native = read("iDeck/NativeRuntime/WineLogTriage.c")
        view = read("iDeck/GameSessionView.swift")
        self.assertIn("WINE_LOG_TAIL_LIMIT = 512 * 1024", native)
        self.assertIn("O_NOFOLLOW", native)
        self.assertIn("ideck_wine_log_diagnose($0)", view)
        self.assertIn(".onChange(of: coordinator.windowsStatus)", view)
        self.assertNotIn("updateRecentWineLogFinding()", view.split(".onReceive(tick)", 1)[1])


if __name__ == "__main__":
    unittest.main()
