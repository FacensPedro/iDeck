"""iDeck 3.1: FNV in-game c000001D, DOOM (2016) on Vulkan, Mafia DE without 2K's launcher,
the whole EA activation log."""
import split_sources  # noqa: F401  (iDeck 3.0 split files)
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(rel):
    return (ROOT / rel).read_text()


class ReadVirtualMemorySafe(unittest.TestCase):
    def test_patch_in_series(self):
        self.assertIn("early     .      madeira-read-virtual-memory-safe.patch", read("patches/series.txt"))

    def test_current_process_read_goes_through_the_kernel(self):
        patch = read("patches/madeira-read-virtual-memory-safe.patch")
        self.assertIn("+++ b/build/ntdll-unix/virtual_ios.c", patch)
        self.assertIn("-            memmove( buffer, addr, size );", patch)
        self.assertIn("+        if (!size || mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)addr, size,", patch)
        self.assertIn("+            size = done;", patch)


class DoomVulkanBuild(unittest.TestCase):
    def test_vulkan_build_replaces_the_opengl_exe(self):
        graphics = read("iDeck/Runtime/WindowsEnvironment+Graphics.swift")
        self.assertIn('static let vulkanBuilds: [String: String] = ["doomx64.exe": "DOOMx64vk.exe"]', graphics)
        self.assertIn('guard vulkanMode != "Off", runtime,', graphics)
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn("func execute(binary requestedBinary: URL,", env)
        self.assertIn("let vulkanOrRequested = vulkanBuild ?? requestedBinary", env)


class GOGPublisherLauncher(unittest.TestCase):
    def test_mafia_direct_executable(self):
        gog = split_sources._original_read_text(ROOT / "iDeck/GOGLibrary.swift")
        self.assertIn('[1993581340: "mafiadefinitiveedition.exe"]', gog)
        self.assertIn('"launcher.exe"', gog)
        self.assertIn("if let primary, isPublisherLauncher(primary[\"path\"] as? String),", gog)
        self.assertIn('["setup", "config", "setting", "tool", "editor", "unins"]', gog)


class EAActivationRows(unittest.TestCase):
    def test_only_style_rules_are_dropped(self):
        report = split_sources._original_read_text(ROOT / "iDeck/BugReportView.swift")
        self.assertIn('let style = text.contains("{") || text.contains("}")', report)


if __name__ == "__main__":
    unittest.main()


class BethesdaDirectLaunch(unittest.TestCase):
    def test_launchers_map_to_games(self):
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        for pair in ('"falloutnvlauncher.exe": "FalloutNV.exe"', '"fallout4launcher.exe": "Fallout4.exe"',
                     '"skyrimselauncher.exe": "SkyrimSE.exe"', '"oblivionlauncher.exe": "Oblivion.exe"',
                     '"falloutlauncher.exe": "Fallout3.exe"', '"skyrimlauncher.exe": "TESV.exe"'):
            self.assertIn(pair, env)
        self.assertIn("let binary = bethesdaGame ?? vulkanOrRequested", env)


class FailedSessionWineLog(unittest.TestCase):
    def test_failed_launch_log_kept_and_copyable(self):
        diag = read("iDeck/Application/SystemCoordinator+Diagnostics.swift")
        self.assertIn('appendingPathComponent("madeira-log.failed.txt", isDirectory: false)', diag)
        end = read("iDeck/Application/SystemCoordinator+SessionEnd.swift")
        self.assertIn("Self.keepFailedSessionLog(game: endedGame ?? \"unknown\", since: wineLogStartOffset)", end)
        screen = read("iDeck/Presentation/BugReport/BugReportScreen.swift")
        self.assertIn('tr("Copy Wine log of the last failed launch")', screen)
        loc = read("iDeck/Localization.swift")
        self.assertIn('"Copy Wine log of the last failed launch": ["pt":', loc)


class UbisoftIntegrity(unittest.TestCase):
    def test_slices_and_files_checked(self):
        inst = read("iDeck/Stores/Ubisoft/UbisoftInstaller.swift")
        self.assertIn("Insecure.SHA1.hash(data: bytes)", inst)
        self.assertIn('throw UbisoftDemuxError.refused("slice SHA-1 mismatch")', inst)
        self.assertIn("if size == file.size { finished.insert(file.name) } else { broken += 1 }", inst)
        self.assertIn('throw UbisoftDemuxError.malformed("file \\(file.name) incomplete")', inst)


class AutoDLLValidation(unittest.TestCase):
    def test_extracted_and_copied_dlls_validated(self):
        cache = read("iDeck/Runtime/AutoDLL/AutoDLLCache.swift")
        self.assertIn("static func isValidDLL(_ file: URL, machine: UInt16) -> Bool", cache)
        self.assertIn("guard count > 0, valid > 0 else", cache)
        inst = read("iDeck/Runtime/AutoDLL/AutoDLLInstaller.swift")
        self.assertIn("guard isValidDLL(source, machine: machine) else", inst)
        self.assertIn('(line.contains("library ") && line.contains("not found"))', inst)

    def test_detection_reads_delay_imports_and_checks_d3dx(self):
        dep = read("iDeck/SessionCompatibility.swift")
        self.assertIn("directories + 13 * 8", dep)
        self.assertIn('static let checkedDirectXPrefixes = ["d3dx9_", "d3dx10_", "d3dx11_", "d3dcompiler_", "d3dcsx_"]', dep)
        self.assertIn("if isProvided(name) { continue }", dep)


class SessionLifecycleMonitor(unittest.TestCase):
    def test_durations_monitor_and_recovering_from_idle(self):
        life = read("iDeck/Application/SessionLifecycle.swift")
        self.assertIn(".idle: [.preparing, .launching, .failed, .recovering],", life)
        self.assertIn("static let stallSeconds: [State: TimeInterval]", life)
        self.assertIn('"[session] stalled: ', life)
        self.assertIn("func observe(_ observer: @escaping (State, State) -> Void)", life)


class StoreProviderLayer(unittest.TestCase):
    def test_five_providers_and_shared_uses(self):
        sp = read("iDeck/Stores/StoreProvider.swift")
        self.assertIn("protocol StoreProvider: AnyObject", sp)
        for name in ("SteamStoreProvider()", "GOGStoreProvider()", "EpicStoreProvider()", "EAStoreProvider()",
                     "UbisoftStoreProvider()"):
            self.assertIn(name, sp)
        self.assertIn("static func pauseAll() -> [StoreGameRef]", sp)
        pbx = read("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(pbx.count("StoreProvider.swift"), 6)
        self.assertIn("path = Stores/StoreProvider.swift;", pbx)
        bugs = read("iDeck/Presentation/BugReport/BugReportModel.swift")
        self.assertIn("lines += StoreProviders.summary.map", bugs)


class ResourceGovernorDomains(unittest.TestCase):
    def test_four_domains_with_levels(self):
        rd = read("iDeck/Runtime/Resources/ResourceDomains.swift")
        self.assertIn("case fex, jit, gpu, sessions", rd)
        self.assertIn('case automatic = "Automatic", economy = "Economy", performance = "Performance"', rd)
        self.assertIn("if profile.cpuCount == 0 { plan.cpuCount = min(4, cores) }", rd)
        self.assertIn("case .economy: plan.jitPoolMiB = 384", rd)
        self.assertIn("WindowsEnvironment.lowMemoryFrameLatency = true", rd)
        pbx = read("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(pbx.count("ResourceDomains.swift"), 6)

    def test_wired_into_launch_settings_and_background(self):
        prof = read("iDeck/Runtime/WindowsEnvironment+Profile.swift")
        self.assertIn("let plan = ResourceDomains.apply(profile: profile)", prof)
        self.assertIn("if sessionJITPoolMiB == 0, let pool = plan.jitPoolMiB { sessionJITPoolMiB = pool }", prof)
        self.assertIn("ResourceDomains.current.pauseInBackground ?? Self.pauseInBackground",
                      read("iDeck/Runtime/Resources/ResourceGovernor+Background.swift"))
        self.assertIn("ResourceDomains.sessionEnded()", read("iDeck/ResourceGovernor.swift"))
        self.assertIn("ResourceLevelPicker(domain: domain)", read("iDeck/Presentation/Settings/SettingsView+System.swift"))


class UnixTryThroughMach(unittest.TestCase):
    def test_patch_resumes_at_except(self):
        self.assertIn("early     .      madeira-unix-try-mach-fault.patch", read("patches/series.txt"))
        patch = read("patches/madeira-unix-try-mach-fault.patch")
        self.assertIn("+++ b/build/ntdll-unix/signal_arm64_ios.c", patch)
        self.assertIn("+            __darwin_arm_thread_state64_set_pc_fptr( *state, (void *)longjmp );", patch)
        self.assertIn("+            td->jmp_buf = NULL;", patch)
        self.assertIn("fsp >= kstack + kernel_stack_size", patch)


class SystemLibrariesAudit(unittest.TestCase):
    def test_audit_sections(self):
        import json
        data = json.loads(read("docs/ios-system-libraries.json"))
        self.assertEqual(set(data["audit"]["evaluated_by_name"]), {"CoreLocation", "StoreKit", "JavaScriptCore"})
        self.assertIn("IOKit", data["audit"]["madeira_link"]["frameworks"])
        self.assertIn("libFEXCore.a", data["audit"]["madeira_link"]["static_archives"])
        self.assertEqual(data["audit"]["unreviewed"], [])
        self.assertIn("coverage_with_madeira_percent", data["summary"])
        self.assertTrue(all("api_symbols" in row for row in data["frameworks"]))


class GraphicsImprovements(unittest.TestCase):
    def test_metalfx_short_side_and_d3d12_fallback_and_cache(self):
        prof = read("iDeck/Runtime/WindowsEnvironment+Profile.swift")
        self.assertIn("if screenShortSide > 0 { factor = min(factor, Double(screenShortSide) / min(width, height)) }", prof)
        gfx = read("iDeck/Runtime/WindowsEnvironment+Graphics.swift")
        self.assertIn("enum D3D12Fallback", gfx)
        self.assertIn("if D3D12Fallback.isOn(binary), let argument = Self.engineAPIArgument(binary: binary, preferD3D12: false)", gfx)
        end = read("iDeck/Application/SystemCoordinator+SessionEnd.swift")
        self.assertIn("D3D12Fallback.note(program, loadedD3D12:", end)
        env = read("iDeck/WindowsEnvironment.swift")
        self.assertIn('setenv("DXMT_SHADER_CACHE_MAX_MB", small ? "64" : "128", 1)', env)


class AuthenticationServicesAdoption(unittest.TestCase):
    def test_sign_in_sheet_for_ea_and_epic(self):
        web = read("iDeck/Stores/WebSignIn.swift")
        self.assertIn("import AuthenticationServices", web)
        self.assertIn("ASWebAuthenticationSession(url: url, callback: .customScheme(scheme))", web)
        self.assertIn("session.prefersEphemeralWebBrowserSession = false", web)
        self.assertIn("func finish()", web)
        self.assertIn('try await WebSignIn.shared.start(url: url, scheme: "qrc")', read("iDeck/EASignIn.swift"))
        epic = read("iDeck/EpicGames.swift")
        self.assertIn("WebSignIn.shared.finish()", epic)
        self.assertIn('WebSignIn.shared.start(url: url, scheme: "ideck-epic-signin")', epic)
        self.assertEqual(read("iDeck.xcodeproj/project.pbxproj").count("WebSignIn.swift"), 6)


class QuickLookAdoption(unittest.TestCase):
    def test_preview_before_sharing(self):
        screen = read("iDeck/Presentation/BugReport/BugReportScreen.swift")
        self.assertIn("import QuickLook", screen)
        self.assertIn(".quickLookPreview($model.previewURL)", screen)
        self.assertIn('tr("Preview before sharing")', screen)
        model = read("iDeck/Presentation/BugReport/BugReportModel.swift")
        self.assertIn("func previewReport()", model)
        self.assertIn("try await WineLogClipboard.redactedSnapshot(from: url, name: name)", model)
        clip = read("iDeck/WineLogClipboard.swift")
        self.assertIn("static func redactedSnapshot(from source: URL, name: String) async throws -> URL", clip)
        self.assertIn("PrivacyRedactor.redact(", clip)


class StoreScreensUseProviders(unittest.TestCase):
    def test_pages_and_library_call_the_providers(self):
        pages = {
            "iDeck/Presentation/GameDetails/SteamProgramDetailsView.swift": ["StoreProviders.of(.steam).install(", "StoreProviders.of(.steam).uninstall("],
            "iDeck/Presentation/GameDetails/SteamProgramDetailsView+Sections.swift": ["StoreProviders.of(.steam).pause(", "StoreProviders.of(.steam).cancel("],
            "iDeck/Presentation/GameDetails/GOGGameDetailsSheet.swift": ["StoreProviders.of(.gog).pause(", "StoreProviders.of(.gog).uninstall("],
            "iDeck/Presentation/GameDetails/EpicGameDetailsSheet.swift": ["StoreProviders.of(.epic).install(", "StoreProviders.of(.epic).uninstall("],
            "iDeck/Presentation/GameDetails/EAGameDetailsSheet.swift": ["StoreProviders.of(.ea).install(", "StoreProviders.of(.ea).uninstall("],
            "iDeck/Presentation/GameDetails/UbisoftGameDetailsSheet.swift": ["StoreProviders.of(.ubisoft).install("],
            "iDeck/Presentation/Library/WindowsWorkspaceView+Steam.swift": ["StoreProviders.of(.steam).install("],
            "iDeck/Presentation/Library/WindowsWorkspaceView+GOG.swift": ["StoreProviders.of(.gog).install("],
        }
        for path, calls in pages.items():
            text = split_sources._original_read_text(ROOT / path)
            for call in calls:
                self.assertIn(call, text, path)
        for path in pages:
            text = split_sources._original_read_text(ROOT / path)
            for old in ("steamLibrary.startInstall(", "steamLibrary.pauseInstall(", "steamLibrary.cancelInstall(",
                        "gog.pauseDownload(", "gog.cancelDownload(", "ea.install(", "ubisoft.install(game)"):
                self.assertNotIn(old, text, path)
        sp = read("iDeck/Stores/StoreProvider.swift")
        self.assertIn("static func of(_ store: GameStore) -> any StoreProvider", sp)
        self.assertIn("onFinish: (@MainActor () -> Void)?) -> Bool", sp)


class StoreScreensReadProviders(unittest.TestCase):
    def test_pages_and_cards_read_state_from_providers(self):
        sp = read("iDeck/Stores/StoreProvider.swift")
        self.assertIn("struct StoreDownloadStatus: Equatable, Sendable", sp)
        self.assertIn("func downloadStatus(_ id: String) -> StoreDownloadStatus?", sp)
        self.assertIn("var installedIDs: Set<String> { get }", sp)
        self.assertIn("var downloadIDs: Set<String> { get }", sp)
        reads = {
            "iDeck/Presentation/GameDetails/GOGGameDetailsSheet.swift": "StoreProviders.of(.gog).downloadStatus(",
            "iDeck/Presentation/GameDetails/EAGameDetailsSheet.swift": "StoreProviders.of(.ea).downloadStatus(",
            "iDeck/Presentation/GameDetails/EpicGameDetailsSheet.swift": "StoreProviders.of(.epic).downloadStatus(",
            "iDeck/Presentation/GameDetails/UbisoftGameDetailsSheet.swift": "StoreProviders.of(.ubisoft).downloadStatus(",
            "iDeck/Presentation/GameDetails/SteamProgramDetailsView.swift": "StoreProviders.of(.steam).downloadStatus(",
            "iDeck/Presentation/GameDetails/SteamProgramDetailsView+Sections.swift": "StoreProviders.of(.steam).downloadStatus(",
            "iDeck/Presentation/Library/WindowsWorkspaceView+Steam.swift": "steamStore.installedIDs",
            "iDeck/Presentation/Library/WindowsWorkspaceView+Epic.swift": "StoreProviders.of(.epic).downloadStatus(",
            "iDeck/Presentation/Library/WindowsWorkspaceView+EA.swift": "StoreProviders.of(.ea).downloadStatus(",
            "iDeck/Presentation/Library/WindowsWorkspaceView+Ubisoft.swift": "StoreProviders.of(.ubisoft).downloadStatus(",
            "iDeck/Presentation/Library/WindowsWorkspaceView+Shelves.swift": "StoreProviders.of(.ea).installedOrDownloadingIDs",
            "iDeck/MainView.swift": "StoreProviders.of(.gog)",
        }
        for path, call in reads.items():
            self.assertIn(call, split_sources._original_read_text(ROOT / path), path)
        old_reads = ("steamLibrary.pausedInstalls", "steamLibrary.downloadErrors", "steamLibrary.waitingApps",
                     "steamLibrary.cancellingApps", "gog.pausedDownloads", "gog.downloadETASeconds",
                     "gog.downloadedBytes", "ea.downloads[", "ubisoft.downloads[", "ubisoftLibrary.downloads[",
                     "eaLibrary.downloads[", "epicLibrary.downloads[")
        for path in reads:
            text = split_sources._original_read_text(ROOT / path)
            for old in old_reads:
                self.assertNotIn(old, text, path)


class DLCScreensUseProviders(unittest.TestCase):
    def test_dlc_through_providers(self):
        sp = read("iDeck/Stores/StoreProvider.swift")
        self.assertIn("struct StoreDLC: Hashable, Sendable", sp)
        for requirement in ("func dlcs(of gameID: String) -> [StoreDLC]",
                            "func dlcDownloadStatus(_ dlcID: String, of gameID: String) -> StoreDownloadStatus?",
                            "@discardableResult func installDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool",
                            "func cancelDLC(_ dlcID: String, of gameID: String)",
                            "@discardableResult func uninstallDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool",
                            "func loadDLC(of gameID: String, prefix: URL?) async"):
            self.assertIn(requirement, sp)
        self.assertIn("model.startDLCInstall(appID: app, dlcAppID: dlc, prefixPath: prefix)", sp)
        self.assertIn("model.installDLC(dlcID)", sp)
        steam = split_sources._original_read_text(ROOT / "iDeck/Presentation/GameDetails/SteamProgramDetailsView+Sections.swift")
        self.assertIn("let dlcs = steamStore.dlcs(of: gameID)", steam)
        self.assertIn("steamStore.installDLC(dlc.id, of: gameID, prefix: prefixPath)", steam)
        for old in ("steamLibrary.availableDLC", "steamLibrary.installingDLC", "steamLibrary.cancelDLCInstall",
                    "steamLibrary.uninstallDLC", "steamLibrary.startDLCInstall", "steamLibrary.dlcMetadata"):
            self.assertNotIn(old, steam)
        page = split_sources._original_read_text(ROOT / "iDeck/Presentation/GameDetails/SteamProgramDetailsView.swift")
        self.assertIn("StoreProviders.of(.steam).installingDLC(of: String(game.appID))", page)
        epic = split_sources._original_read_text(ROOT / "iDeck/Presentation/GameDetails/EpicGameDetailsSheet.swift")
        self.assertIn("epicStore.installDLC(dlc.id, of: appName, prefix: nil)", epic)
        for old in ("epic.dlcs[", "epic.installDLC(", "epic.uninstallDLC(", "epic.installedDLC["):
            self.assertNotIn(old, epic)


class EpicPacksThroughProvider(unittest.TestCase):
    def test_optional_packs(self):
        sp = read("iDeck/Stores/StoreProvider.swift")
        self.assertIn("struct StoreOptionalPack: Hashable, Sendable", sp)
        self.assertIn("model.installPack(gameID, tag: packID)", sp)
        page = split_sources._original_read_text(ROOT / "iDeck/Presentation/GameDetails/EpicGameDetailsSheet.swift")
        self.assertIn("StoreProviders.of(.epic).optionalPacks(of: appName)", page)
        self.assertIn("epicStore.installPack(pack.id, of: appName)", page)
        for old in ("epic.installPack(", "epic.uninstallPack(", "epic.packInstalled(", "epic.optionalPacks[", "epic.loadOptionalPacks("):
            self.assertNotIn(old, page)


class MainViewSteamThroughProvider(unittest.TestCase):
    def test_main_view_steam_state(self):
        main = split_sources._original_read_text(ROOT / "iDeck/MainView.swift")
        self.assertIn("await StoreProviders.of(.steam).refresh()", main)
        self.assertIn("StoreProviders.of(.steam).refreshInstalled(prefix: prefixPath)", main)
        self.assertIn("steamStore.downloadState(id)?.isRunning == true", main)
        for old in ("steamLibrary.refreshInstalledApps(", "steamLibrary.installingApps", "steamLibrary.installedApps", "await steamLibrary.refresh()"):
            self.assertNotIn(old, main)
        self.assertIn("func refreshInstalled(prefix: URL) { model.refreshInstalledApps(prefixPath: prefix) }",
                      read("iDeck/Stores/StoreProvider.swift"))


class GOGInstalledScanThroughProvider(unittest.TestCase):
    def test_gog_refresh_installed(self):
        main = split_sources._original_read_text(ROOT / "iDeck/MainView.swift")
        self.assertEqual(main.count("StoreProviders.of(.gog).refreshInstalled(prefix:"), 3)
        self.assertNotIn("gogLibrary.refreshInstalled(", main)
        self.assertIn("func refreshInstalled(prefix: URL) { model.refreshInstalled(prefixPath: prefix) }",
                      read("iDeck/Stores/StoreProvider.swift"))
