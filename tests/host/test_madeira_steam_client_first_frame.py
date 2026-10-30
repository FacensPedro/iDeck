import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
RENDERER = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()


class MadeiraSteamClientFirstFrameTests(unittest.TestCase):
    def test_steam_client_loader_does_not_claim_running_without_first_frame(self):
        start = COORDINATOR.index('self.withPreparedMetalDisplay(expectedStatus: "Launching Steam client...")')
        end = COORDINATOR.index('private func withPreparedMetalDisplay(', start)
        launch = COORDINATOR[start:end]
        self.assertIn('let loaderAlive = result && ideck_wineprocess_running()', launch)
        self.assertIn('"Wine started; waiting for game..."', launch)
        self.assertIn('Steam client Wine thread started; awaiting Metal first frame', launch)
        self.assertNotIn('? "Steam Running"', launch)
        self.assertIn('Execution Error: Windows Steam client failed to start.', launch)

    def test_native_layer_registration_must_complete_before_launching_wine(self):
        start = RENDERER.index('static var isReadyForFrames: Bool')
        end = RENDERER.index('static var requestedSize:', start)
        gate = RENDERER[start:end]
        self.assertIn('guard isNativeDisplayLinked, layerRegistered,', gate)
        self.assertIn('host.superview === window', gate)
        self.assertIn('host.metalLayer.device != nil', gate)
        self.assertIn('host.bounds.width >= 2', gate)
        self.assertIn('host.bounds.height >= 2', gate)
        self.assertIn('setter(Unmanaged.passUnretained(host.metalLayer).toOpaque())', RENDERER)
        self.assertLess(RENDERER.index('setter(Unmanaged.passUnretained(host.metalLayer).toOpaque())'),
                        RENDERER.index('layerRegistered = true'))

    def test_only_counter_advance_promotes_wine_to_running(self):
        self.assertIn('metrics.receivedNewFrames', SESSION)
        self.assertIn('coordinator.windowsStatus == "Wine started; waiting for game..."', SESSION)
        self.assertIn('coordinator.setWindowsStatus("Running")', SESSION)
        self.assertIn('metrics.secondsSinceLaunch >= 20 && !metrics.receivedNewFrames', SESSION)
        self.assertIn('Wine started, but no game frame was detected.', SESSION)
        self.assertIn('WindowsRendererView.refreshNativeDisplay()', SESSION)

    def test_wine_launch_waits_for_attached_metal_display(self):
        self.assertIn('WindowsRendererView.isReadyForFrames', COORDINATOR)
        self.assertIn('Metal display surface did not become ready. Wine was not started.', COORDINATOR)


if __name__ == "__main__":
    unittest.main()
