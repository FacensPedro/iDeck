import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text(encoding="utf-8")
STEAM = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
DEPOT = (ROOT / "iDeck/SteamDepotDownloader.swift").read_text(encoding="utf-8")


class AutomaticJITAndDownloadHUDTests(unittest.TestCase):
    def test_wine_jit_auto_prepare_only_with_live_debugger_and_real_runtime(self):
        self.assertIn("wineJITPreparationInFlight", COORDINATOR)
        self.assertIn("wineJITAttemptedDuringAttachment", COORDINATOR)
        self.assertIn("else if detected && !wineReady", COORDINATOR)
        self.assertIn("if native.fex_linked && native.launcher_linked", COORDINATOR)
        self.assertIn("let prepared = ideck_wine_jit_pool_prepare()", COORDINATOR)
        self.assertIn("if !debuggerAttached {", COORDINATOR)
        self.assertIn("DispatchQueue.global(qos: .userInitiated)", COORDINATOR)
        # The main thread never waits on the pool mutex: snapshot try-locks.
        self.assertIn("(wineJITPreparationInFlight || snapshot.wine_state_busy)", COORDINATOR)
        self.assertIn("? isWineJITPrepared : snapshot.wine_pool_prepared", COORDINATOR)
        # The last working pool size is tried first next time.
        self.assertIn('getenv("IDECK_WINE_JIT_LAST_GOOD_MIB")', (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text())
        self.assertIn('UserDefaults.standard.set(poolMiB, forKey: Self.lastGoodPoolKey)', COORDINATOR)
        # A pool-size preference was added after the original automatic-JIT
        # test. It is safe because it only configures the native allocation
        # before preparation; the app must not resize an executable JIT pool.
        self.assertIn('Text(tr("Wine JIT pool"))', SETTINGS)
        self.assertIn('@AppStorage("wineJITPoolMiB")', SETTINGS)
        self.assertIn('ForEach([384, 512, 640, 768, 896, 1152]', SETTINGS)
        self.assertIn('updateWineJITPoolPreference(selected)', SETTINGS)
        self.assertIn('guard !wineJITPreparationInFlight && !ideck_wine_jit_pool_ready()', COORDINATOR)
        self.assertIn('setenv("IDECK_WINE_JIT_MIB", String(sizeMiB), 1)', COORDINATOR)
        self.assertIn('unsetenv("IDECK_WINE_JIT_MIB")', COORDINATOR)

    def test_updates_settings_hide_unnecessary_release_messages(self):
        self.assertNotIn('actionButton(title: tr("Update iDeck %@", update.latest ?? "")', SETTINGS)
        for literal in (
            'actionButton(title: tr("Open iDeck releases")',
            "No newer iDeck IPA release is available.",
            "iPadOS requires a signed IPA installation",
        ):
            self.assertNotIn(literal, SETTINGS)

    def test_overlay_defaults_off_and_never_claims_gpu_utilization(self):
        self.assertIn('@AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false', SETTINGS)
        self.assertIn('@AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false', SESSION)
        self.assertIn('coordinator.windowsStatus == "Running"', SESSION)
        self.assertIn("metrics.receivedNewFrames", SESSION)
        self.assertIn("if showGamePerformanceOverlay &&", SESSION)
        self.assertIn('Text("FPS:', SESSION)
        self.assertIn('Text("GPU memory (Metal):', SESSION)
        self.assertIn('Text("GPU utilization: unavailable on iOS")', SESSION)
        self.assertIn("if horizontalSizeClass != .compact {", SESSION)
        self.assertIn("if collectPerformance && getrusage(", SESSION)

    def test_log_copy_is_only_offered_when_session_has_problems(self):
        self.assertIn("private var hasWineProblem: Bool", SESSION)
        self.assertIn("if hasWineProblem && wineLogURL != nil", SESSION)
        self.assertIn('status.hasPrefix("Execution Error")', SESSION)
        self.assertIn("metrics.secondsSinceLaunch >= 20 && !metrics.receivedNewFrames", SESSION)

    def test_faster_chunks_still_respect_thermal_and_low_power_modes(self):
        self.assertIn("if process.isLowPowerModeEnabled { return 2 }", DEPOT)
        self.assertIn("case .critical: return 1", DEPOT)
        self.assertIn("case .nominal: return DownloadSpeed.isUnlimited", DEPOT)
        self.assertIn("min(DownloadSpeed.steamChunks, max(32, process.activeProcessorCount * 8))", DEPOT)
        self.assertIn("case .serious: return 4", DEPOT)
        self.assertIn("config.httpMaximumConnectionsPerHost = 64", DEPOT)
        self.assertIn("let readers = isExternal ? 3 : min(12", DEPOT)
        self.assertIn("try await withThrowingTaskGroup", DEPOT)
        self.assertIn("SteamChunkScheduler.batches(paths:", DEPOT)

    def test_cancel_removes_owned_files_but_preserves_preexisting_unowned_data(self):
        self.assertIn("let installOwnership = steamApps.appendingPathComponent(", STEAM)
        self.assertIn('.ideck-owned-folder"', STEAM)
        self.assertIn("ownsIncompleteInstall = !wasInstalled &&", STEAM)
        self.assertIn("savedOwner == installFolder", STEAM)
        self.assertIn("if cancelled, !wasInstalled {", STEAM)
        self.assertIn("if ownsIncompleteInstall, let installFolder {", STEAM)
        self.assertIn("SteamInstallFiles.delete(appID: Int(appID), folderName: installFolder,", STEAM)
        self.assertIn('name != ".ideck-owned-folder"', DEPOT)
        self.assertIn("task.cancel()", STEAM)


if __name__ == "__main__":
    unittest.main()
