import unittest

from support import repo_text


class RuntimeEfficiencyTests(unittest.TestCase):
    """Work iDeck itself does while a game runs (the UI and runtime layers)."""

    def test_native_symbols_are_resolved_once(self):
        symbol = repo_text("iDeck/NativeSymbol.swift")
        self.assertIn("if let known = cache[name] { return known }", symbol)
        for path in ("iDeck/WindowsRendererView.swift", "iDeck/GameSessionView.swift",
                     "iDeck/WindowsEnvironment.swift", "iDeck/TouchMouseView.swift"):
            with self.subTest(path=path):
                self.assertNotIn("dlsym(", repo_text(path))

    def test_session_metrics_publish_only_visible_changes(self):
        session = repo_text("iDeck/GameSessionView.swift")
        metrics = session.split("private final class GameRuntimeMetrics", 1)[1].split("struct GameSessionView", 1)[0]
        self.assertNotIn("@Published private(set) var frameCount", metrics)
        self.assertIn("if self[keyPath: key] != value { self[keyPath: key] = value }", metrics)
        self.assertIn("if !receivedNewFrames || elapsed - (firstFrameAt ?? elapsed) < 3", metrics)
        self.assertIn("if collectPerformance, let oldTime = previousUptime", metrics)
        self.assertIn("metrics.secondsSinceStart >= 75", session)

    def test_jit_probe_pauses_while_a_game_runs(self):
        self.assertIn("if !ideck_wineprocess_running() { coordinator.refreshJITStatus() }",
                      repo_text("iDeck/MainView.swift"))

    def test_transfers_run_below_the_game(self):
        self.assertIn('DispatchQueue(label: "ideck.irelay.service", qos: .utility)',
                      repo_text("iDeck/IRelayDeviceService.swift"))

    def test_platform_layer_keeps_only_used_entry_points(self):
        platform = repo_text("iDeck/NativeRuntime/MadeiraPlatform.mm")
        for kept in ("ideck_metal_available", "ideck_dxmt_available", "ideck_d3d12_available", "ideck_session_stop"):
            self.assertIn(kept, platform)
        for removed in ("ideck_metal_renderer_create", "ideck_metal_swapchain_create", "PROT_EXEC",
                        "ideck_native_memory_install_notifications"):
            self.assertNotIn(removed, platform)


if __name__ == "__main__":
    unittest.main()
