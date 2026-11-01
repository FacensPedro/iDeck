import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class GOGIntegrationTests(unittest.TestCase):
    def test_sign_in_uses_gog_page_and_keychain(self):
        gog = read("iDeck/GOGLibrary.swift")
        self.assertIn('"https://auth.gog.com/auth"', gog)
        self.assertIn('static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"', gog)
        self.assertIn("configuration.websiteDataStore = .nonPersistent()", gog)
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", gog)
        self.assertIn('URLQueryItem(name: "grant_type", value: "refresh_token")', gog)
        # Tokens are refreshed before expiry and never logged.
        self.assertIn("guard stored.isExpired else { return stored }", gog)
        self.assertNotIn("accessToken)\")", gog)

    def test_library_installer_and_installed_detection(self):
        gog = read("iDeck/GOGLibrary.swift")
        self.assertIn("/account/getFilteredProducts?mediaType=1&sortBy=title&page=", gog)
        self.assertIn('"/account/gameDetails/\\(gameID).json"', gog)
        self.assertIn('URL(string: "https://www.gog.com" + file.manualURL)', gog)
        self.assertIn('file.hasPrefix("goggame-") && file.hasSuffix(".info")', gog)
        self.assertIn('!relative.contains("..")', gog)
        self.assertIn('"drive_c/WindowsDownloads"', gog)

    def test_new_sources_are_in_the_xcode_project(self):
        project = read("iDeck.xcodeproj/project.pbxproj")
        for name in ("GOGLibrary.swift", "BugReportView.swift"):
            self.assertEqual(project.count(f"path = {name};"), 1, name)
            self.assertEqual(project.count(f"/* {name} in Sources */,"), 1, name)


class LibraryPresentationTests(unittest.TestCase):
    def test_store_badges_next_to_names(self):
        view = read("iDeck/MainView.swift")
        self.assertIn("private func cardTitle(_ title: String, store: GameStore? = nil)", view)
        self.assertGreaterEqual(view.count("store: .steam)"), 2)
        self.assertGreaterEqual(view.count("store: .gog)"), 2)
        badge = read("iDeck/GOGLibrary.swift")
        self.assertIn('UIImage(named: assetName) != nil', badge)

    def test_owned_lists_collapse_and_remember(self):
        view = read("iDeck/MainView.swift")
        self.assertIn('@AppStorage("library.steamOwnedCollapsed")', view)
        self.assertIn('@AppStorage("library.gogOwnedCollapsed")', view)
        self.assertIn("if !steamOwnedCollapsed {", view)
        self.assertIn("if !gogOwnedCollapsed {", view)

    def test_installing_cards_keep_installed_size(self):
        view = read("iDeck/MainView.swift")
        self.assertNotIn("private func downloadControls(", view)
        self.assertIn("private let cardActionHeight: CGFloat = 40", view)
        self.assertIn("steamProgressAction(for: game)", view)


class SettingsAndDiagnosticsTests(unittest.TestCase):
    def test_settings_only_track_ideck_updates(self):
        updater = read("iDeck/UpdateChecker.swift")
        self.assertIn("static let projects: [TrackedProject] = [ideck]", updater)
        for project in ("StikDebug", "LiveContainer", "willfaust"):
            self.assertNotIn(f'owner: "{project}"', updater)

    def test_bug_screen_reads_both_logs_and_copies(self):
        settings = read("iDeck/SettingsView.swift")
        self.assertIn("NavigationLink(destination: BugReportView())", settings)
        bugs = read("iDeck/BugReportView.swift")
        self.assertIn('appendingPathComponent("iDeck-app-log.txt"', bugs)
        self.assertIn('appendingPathComponent("madeira-log.txt"', bugs)
        self.assertIn("UIPasteboard.general.string = report(for: [issue])", bugs)
        self.assertIn("static let maximumBytes: UInt64 = 1024 * 1024", bugs)
        steam = read("iDeck/SteamManager.swift")
        self.assertIn("AppLog.record(message)", steam)

    def test_ubuntu_runners_are_26_04(self):
        for workflow in (ROOT / ".github/workflows").glob("*.yml"):
            text = workflow.read_text(encoding="utf-8")
            self.assertNotIn("ubuntu-latest", text, workflow.name)
            self.assertNotIn("ubuntu-24.04", text, workflow.name)


class MetalFXTests(unittest.TestCase):
    def test_metalfx_reaches_dxmt_and_madeira_d3d12(self):
        env = read("iDeck/WindowsEnvironment.swift")
        self.assertIn('setenv("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1", 1)', env)
        self.assertIn('"d3d11.metalSpatialUpscaleFactor = %.2f"', env)
        self.assertIn('"metalfx-upscale = %.2f"', env)
        self.assertNotIn("MVK_CONFIG_USE_METALFX", env)

    def test_metalfx_factor_matches_dxmt_range(self):
        env = read("iDeck/WindowsEnvironment.swift")
        self.assertIn("let factor = min(Double(screenLongSide) / max(width, height), 2.0)", env)
        self.assertIn("return factor >= 1.1 ?", env)


class SteamConnectionSpeedTests(unittest.TestCase):
    def test_server_list_is_prewarmed_and_shared(self):
        coordinator = read("iDeck/SystemCoordinator.swift")
        self.assertIn("_ = try? await CMServerList.shared.candidates(1)", coordinator)
        steam = read("iDeck/SteamManager.swift")
        self.assertIn('private let cacheKey = "swiftsteam_cm_servers_websocket_v2"', steam)
        self.assertIn("for _ in 0..<200 {", steam)


if __name__ == "__main__":
    unittest.main()


class LegacyVisualCRuntimeTests(unittest.TestCase):
    """Visual C++ 2005-2013 (x86/x64) and the 32-bit 2015-2022 runtime."""

    def test_official_packages_and_layout(self):
        swift = read("iDeck/VisualCRuntimeBootstrap.swift")
        for url in ("8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE",
                    "5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe",
                    "165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe",
                    "VSU_4/vcredist_x64.exe", "https://aka.ms/highdpimfc2013x86enu",
                    "https://aka.ms/vc14/vc_redist.x86.exe"):
            self.assertIn(url, swift)
        self.assertIn('if machine == x86Machine { return "x86/" + name }', swift)
        self.assertIn("ideck_vcrt_extract_set(", swift)

    def test_extractor_handles_pe32_and_msi_names(self):
        c = read("iDeck/NativeRuntime/VCArchiveExtractor.c")
        self.assertIn('else if (machine == 0x014c && magic == 0x10b) directories = 96;', c)
        self.assertIn('{ "f_central_", "fl_", "nosxs_" }', c)

    def test_madeira_links_32bit_and_side_by_side(self):
        patch = read("patches/ideck-vcruntime-wow64.patch")
        self.assertIn("+                ideck_link_vcruntime_wow64(fm, prefix);", patch)
        self.assertIn('@"x86_", assembly', patch)
        self.assertIn("ideck-vcruntime-wow64.patch", read("scripts/fetch_madeira_sources.sh"))
