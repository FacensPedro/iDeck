import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
STEAM = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
GAME = (ROOT / "iDeck/GameSessionView.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")

class SteamWebSocketBackpressureTests(unittest.TestCase):
    def test_receive_uses_single_consumer_before_next_receive(self):
        start = STEAM.index("nonisolated private func scheduleReceive(")
        end = STEAM.index("private func consumeThenReceive(", start)
        receive = STEAM[start:end]
        self.assertIn("Task { await self.consumeThenReceive(data, from: task) }", receive)
        self.assertNotIn("self.scheduleReceive(task)", receive)

    def test_stale_socket_cannot_schedule_new_receive(self):
        start = STEAM.index("private func consumeThenReceive(")
        end = STEAM.index("// MARK: - Send", start)
        consume = STEAM[start:end]
        self.assertEqual(consume.count("guard webSocketTask === task else { return }"), 2)
        self.assertIn("messageHandler?(data)", consume)
        self.assertIn("scheduleReceive(task)", consume)

    def test_wine_process_must_match_requested_game(self):
        self.assertIn("activeSteamGameID == game.appID", COORDINATOR)
        self.assertIn("activeSteamPrefix == standardizedPrefix", COORDINATOR)
        self.assertIn("pendingSteamGameID == game.appID", COORDINATOR)
        self.assertIn("let running = success == 0 && ideck_wineprocess_running()", COORDINATOR)
        self.assertIn("func refreshWindowsSessionHealth()", COORDINATOR)
        self.assertIn("coordinator.refreshWindowsSessionHealth()", GAME)

    def test_metal_surface_required_before_wine_launch(self):
        coordinator = COORDINATOR
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text(encoding="utf-8")
        main = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
        self.assertIn('withPreparedMetalDisplay(expectedStatus: "Launching Steam game...")', coordinator)
        self.assertIn('withPreparedMetalDisplay(expectedStatus: "Launching Windows app...")', coordinator)
        self.assertIn("WindowsRendererView.isReadyForFrames", coordinator)
        self.assertNotIn("asyncAfter(deadline: .now() + 0.3)", coordinator)
        self.assertIn("static var isReadyForFrames", renderer)
        self.assertIn("override func didMoveToWindow()", renderer)
        self.assertIn("guard activeView === view else { return }", renderer)
        self.assertIn("fileprivate static func releaseLayer(for view: MTKView)", renderer)
        runtime = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
        environment = (ROOT / "iDeck/WindowsEnvironment.swift").read_text(encoding="utf-8")
        self.assertIn("Self.isPE32WindowsExecutable(binary)", environment)
        self.assertIn('@"i386-windows/ntdll.dll"', runtime)
        self.assertIn('coordinator.windowsStatus == "Launching Windows app..."', main)

    def test_dlc_requests_stop_after_details_close(self):
        self.assertIn("guard !Task.isCancelled else { return }", STEAM)
        self.assertIn("await steamLibrary.loadDLC(appID: game.appID)", (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8"))

    def test_graphics_diagnostic_requires_elapsed_time(self):
        self.assertIn("metrics.secondsSinceLaunch >= 15 && !metrics.receivedNewFrames", GAME)
        self.assertIn("!WindowsRendererView.isNativeDisplayLinked", GAME)
        self.assertIn("!metrics.presentCounterAvailable", GAME)
        self.assertIn('coordinator.windowsStatus.hasPrefix("Execution Error:")',
                      (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8"))

if __name__ == "__main__":
    unittest.main()
