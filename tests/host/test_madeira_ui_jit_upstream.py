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
