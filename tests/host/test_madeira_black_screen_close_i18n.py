import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MadeiraBlackScreenCloseAndLocalizationTests(unittest.TestCase):
    def test_compositor_sync_is_not_gated_on_window_resizing(self):
        renderer = (ROOT / "iDeck/WindowsRendererView.swift").read_text()
        start = renderer.index("fileprivate static func layoutViewport(")
        end = renderer.index("fileprivate static func detachViewport(", start)
        code = renderer[start:end]
        self.assertIn("if host.frame != positioned", code)
        compositor = code.index('"winios_set_compositor_frame"')
        desktop = code.index('"winios_set_desktop_rect"')
        self.assertGreater(compositor, code.index("if host.frame != positioned"))
        self.assertIn("static func refreshNativeDisplay()", code)
        self.assertIn("attachViewport(viewport)", code)
        self.assertIn("layoutViewport(viewport)", code)
        self.assertIn("Do NOT write host.metalLayer.drawableSize here", code)
        self.assertLess(code.index("if host.frame != positioned"), compositor)
        guard_start = code.index("if host.frame != positioned")
        guard_end = code.index("}\n", guard_start) + 2
        self.assertLess(guard_end, compositor)
        self.assertLess(guard_end, desktop)

    def test_guest_liveness_is_not_reported_as_rendered_app(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        view = (ROOT / "iDeck/GameSessionView.swift").read_text()
        self.assertIn('? "Wine started; waiting for game..." : self.nativeLaunchFailure(result)', coordinator)
        self.assertIn("WindowsRendererView.refreshNativeDisplay()", view)
        self.assertIn("metrics.receivedNewFrames", view)
        self.assertIn('coordinator.setWindowsStatus("Running")', view)

    def test_close_retries_are_bounded_and_safe(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn("private var windowsCloseAttempts = 0", coordinator)
        self.assertIn("windowsCloseAttempts < 3", coordinator)
        self.assertIn("seconds >= Double((windowsCloseAttempts + 1) * 4)", coordinator)
        self.assertIn("ideck_wineprocess_request_close()", coordinator)
        self.assertIn("ideck_wineprocess_thread_finished()", coordinator)
        self.assertIn("ideck_runtime_complete_session()", coordinator)
        self.assertNotIn("kill(getpid()", coordinator)
        self.assertNotIn("pthread_cancel(", coordinator)

    def test_orphan_wineserver_can_only_be_stopped_after_guest_finished(self):
        server = (ROOT / "iDeck/NativeRuntime/WineServerBridge.m").read_text()
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        native = (ROOT / "iDeck/NativeRuntime/MadeiraStaticABI.h").read_text()
        self.assertIn("void wineserver_stop(void);", native)
        self.assertIn("bool ideck_wineserver_stop_if_idle(void)", server)
        self.assertIn("!ideck_wineprocess_thread_finished()", server)
        self.assertIn("ideck_wineprocess_running()", server)
        self.assertIn("dispatch_async(dispatch_get_global_queue(", server)
        self.assertIn("wineserver_stop();", server)
        self.assertIn("ideck_wineserver_stop_if_idle()", coordinator)
        self.assertIn("!ideck_wineprocess_running() && ideck_wineprocess_thread_finished()", coordinator)
        self.assertNotIn("pthread_cancel(", server)
        self.assertNotIn("kill(getpid()", server)

    def test_all_requested_portuguese_and_spanish_ui_strings_exist(self):
        source = (ROOT / "iDeck/Localization.swift").read_text()
        for key in (
            "Closing Wine and wineserver...",
            "Wine did not close",
            "Retry Close",
            "Keep Waiting",
            "Return to Game",
            "Copy JIT diagnostics",
            "JIT diagnostics copied to clipboard",
            "Keep child game processes running (experimental)",
            "Use only when a launcher exits after starting its game.",
        ):
            with self.subTest(key=key):
                pos = source.index('"' + key)
                self.assertIn('"pt":', source[pos:pos + 700])
                self.assertIn('"es":', source[pos:pos + 700])

    def test_jit_copy_is_hidden_without_a_failure_and_update_button_is_removed(self):
        source = (ROOT / "iDeck/SettingsView.swift").read_text()
        self.assertIn("if shouldShowJITDiagnostics {", source)
        self.assertIn("!coordinator.isJITEnabled", source)
        self.assertIn("snapshot.wine_failure_stage != 0", source)
        self.assertIn("snapshot.wine_failure_mach_code != 0", source)
        self.assertNotIn('actionButton(title: tr("Update iDeck %@', source)
        self.assertNotIn("updater.installIDeckUpdate()", source)

    def test_closing_and_child_process_controls_use_translation(self):
        session = (ROOT / "iDeck/GameSessionView.swift").read_text()
        main = (ROOT / "iDeck/MainView.swift").read_text()
        self.assertIn('Text(tr("Closing Wine and wineserver..."))', session)
        self.assertIn('.alert(tr("Wine did not close")', session)
        self.assertIn("Text(tr(coordinator.windowsCloseWarning ?? \"\"))", session)
        self.assertIn('DetailToggleRow(title: tr("Keep child game processes running (experimental)")', main)


if __name__ == "__main__":
    unittest.main()
