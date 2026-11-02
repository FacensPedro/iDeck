import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'iDeck/MainView.swift').read_text()
SETTINGS = (ROOT / 'iDeck/SettingsView.swift').read_text()
INPUT = (ROOT / 'iDeck/InputManager.swift').read_text()
COORDINATOR = (ROOT / 'iDeck/SystemCoordinator.swift').read_text()
FEX = (ROOT / 'iDeck/NativeRuntime/FEXRuntime.cpp').read_text()
HEADER = (ROOT / 'iDeck/NativeRuntime/MadeiraRuntimeBridge.h').read_text()
EXTRACTOR = (ROOT / 'iDeck/NativeRuntime/VCArchiveExtractor.c').read_text()
STEAM = (ROOT / 'iDeck/SteamManager.swift').read_text()

class MadeiraUIJITUpstreamTests(unittest.TestCase):
    def test_home_modes_are_only_short_titles(self):
        home = MAIN.split('private var homeView:', 1)[1].split('struct SteamGameArtworkView:', 1)[0]
        self.assertNotIn('Text("iDeck")', home)
        self.assertNotIn('tr("Choose a mode")', home)
        self.assertNotIn('tr("Madeira Emulator")', MAIN)
        self.assertIn('modeTile(title: tr("Madeira"), symbol:', home)
        self.assertIn('modeTile(title: tr("LiveContainer"), symbol:', home)
        self.assertIn('private func modeTile(title: String, symbol: String)', home)
        self.assertNotIn('Text(subtitle)', home)

    def test_controller_options_only_when_connected(self):
        start = SETTINGS.index('settingsSection(title: tr("Controller"))')
        end = SETTINGS.index('settingsSection(title: tr("Graphics & Performance"))', start)
        segment = SETTINGS[start:end]
        guard = segment.index('if inputManager.isControllerConnected {')
        self.assertLess(guard, segment.index('sensitivityRow(title: tr("Left stick sensitivity")'))
        self.assertLess(guard, segment.index('Slider(value: $controllerDeadzone'))
        self.assertIn('inputManager.refreshControllers()', SETTINGS)
        self.assertIn('GCController.controllers()', INPUT)
        self.assertIn('DispatchQueue.main.async', INPUT)

    def test_stikdebug_only_requested_when_launching_without_jit(self):
        home = MAIN.split('private var homeView:', 1)[1].split('private func modeTile', 1)[0]
        self.assertIn('coordinator.openMadeiraWorkspace()', home)
        self.assertNotIn('requestStikDebugJIT()', home)
        self.assertNotIn('reconnectStikDebugForWineIfNeeded()', home)
        self.assertIn('func ensureJITForGameLaunch() -> Bool', COORDINATOR)
        guard = COORDINATOR.split('private func ensureJITForGameLaunch() -> Bool {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('snapshot.wine_pool_prepared && ideck_fex_jit_ready() { return true }', guard)
        self.assertIn('ideck_process_has_jit_permission()', guard)
        self.assertIn('waitForDebuggerThenResume(resume)', guard)
        self.assertEqual(guard.count('requestStikDebugJIT()'), 1)
        self.assertIn('no new authorization was requested', guard)
        self.assertIn('URLQueryItem(name: "script-data"', COORDINATOR)
        self.assertIn('coordinator.isJITEnabled ? "Reconnect JIT debugger" : "Enable JIT"', SETTINGS)

    def test_launch_waits_for_pool_completion_without_blocking_ui(self):
        wait = COORDINATOR.split('private func waitForDebuggerThenResume(', 1)[1].split('@discardableResult', 1)[0]
        self.assertNotIn('ideck_wine_jit_pool_ready()', wait)
        self.assertIn('!wineJITPreparationInFlight && !snapshot.wine_state_busy', wait)
        self.assertIn('snapshot.wine_pool_prepared && ideck_fex_jit_ready()', wait)
        self.assertNotIn('ideck_jit_debugger_attached() ||', wait)
        self.assertIn('!reconnected', wait)
        self.assertIn('reconnected = true', wait)
        self.assertIn('setWindowsStatus(nativeLaunchFailure(Int(ENOMEM)))', wait)
        self.assertIn('guard generation == jitWaitGeneration else { return }', wait)
        self.assertIn('ideck_fex_initialize() && ideck_wine_jit_pool_prepare()', COORDINATOR)

    def test_wine_jit_inspects_split_executable_rx_safely(self):
        self.assertIn('void prepare_wine_pool_frontier()', FEX)
        self.assertIn('wine_pool_low_va_pins.push_back(address);', FEX)
        self.assertIn('while (cursor < end)', FEX)
        self.assertIn('vm_region_64(', FEX)
        self.assertIn('VM_PROT_EXECUTE', FEX)
        self.assertIn('ideck_wine_jit_pool_failure_rx_detail(void);', HEADER)
        rejected = FEX.split('if (!acceptable_pool(rx, size)) {', 1)[1].split('// Madeira\'s 63 GiB', 1)[0]
        self.assertNotIn('vm_deallocate(', rejected)
        self.assertIn('switch ideck_wine_jit_pool_failure_rx_detail()', COORDINATOR)

    def test_dll_extraction_stops_at_verified_completion(self):
        self.assertIn('unsigned int found_count;', EXTRACTOR)
        self.assertIn('if ((int)state->found_count == state->count) goto finish;', EXTRACTOR)
        self.assertIn('valid_pe(path, state->machine, state->require_cert)', EXTRACTOR)
        self.assertIn('state->found_count++;', EXTRACTOR)

    def test_background_downloads_are_balanced(self):
        background = (ROOT / "iDeck/BackgroundDownloads.swift").read_text()
        self.assertIn('beginBackgroundTask(', background)
        self.assertIn('UIApplication.shared.endBackgroundTask(graceTask)', background)
        self.assertIn('BGContinuedProcessingTaskRequest', background)
        # Every started Steam download reports its end, also when it fails.
        self.assertEqual(STEAM.count('BackgroundDownloads.steam.started('), 2)
        self.assertEqual(STEAM.count('BackgroundDownloads.steam.ended('), 2)

if __name__ == '__main__':
    unittest.main()
