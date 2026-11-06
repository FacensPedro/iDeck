import unittest
from pathlib import Path

from support import ROOT, repo_text
MAIN = repo_text("iDeck/MainView.swift")
SETTINGS = repo_text("iDeck/SettingsView.swift")
INPUT = repo_text("iDeck/InputManager.swift")
COORDINATOR = repo_text("iDeck/SystemCoordinator.swift")
FEX = repo_text("iDeck/NativeRuntime/FEXRuntime.cpp")
HEADER = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.h")
EXTRACTOR = repo_text("iDeck/NativeRuntime/VCArchiveExtractor.c")
STEAM = repo_text("iDeck/SteamManager.swift")

class MadeiraUIJITUpstreamTests(unittest.TestCase):
    def test_madeira_is_root_view_without_livecontainer(self):
        self.assertIn('WindowsWorkspaceView(coordinator: coordinator, steamLibrary: steamLibrary)', MAIN)
        self.assertIn('Text("iDeck")', MAIN)
        self.assertNotIn('Image("IDeckLogo")', MAIN)
        self.assertNotIn('homeView', MAIN)
        self.assertNotIn('LiveContainer', MAIN)
        self.assertNotIn('appManager', MAIN)
        self.assertNotIn('modeTile', MAIN)

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
        background = repo_text("iDeck/BackgroundDownloads.swift")
        self.assertIn('beginBackgroundTask(', background)
        self.assertIn('UIApplication.shared.endBackgroundTask(graceTask)', background)
        self.assertIn('BGContinuedProcessingTaskRequest', background)
        # Every started Steam download reports its end, also when it fails.
        self.assertEqual(STEAM.count('BackgroundDownloads.steam.started('), 2)
        self.assertEqual(STEAM.count('BackgroundDownloads.steam.ended('), 2)

if __name__ == '__main__':
    unittest.main()
