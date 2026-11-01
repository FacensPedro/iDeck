import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
MAIN = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")
SERVER = (ROOT / "iDeck/NativeRuntime/WineServerBridge.m").read_text(encoding="utf-8")
INPUT = (ROOT / "iDeck/WineInputBridge.swift").read_text(encoding="utf-8")


class WineCloseSessionTests(unittest.TestCase):
    def test_x_requests_real_shutdown_without_dismissing_active_wine(self):
        self.assertIn("Button(action: coordinator.requestCloseWindowsSession)", SESSION)
        self.assertIn('Close Wine and return to the library', SESSION)
        self.assertNotIn("presentationMode.wrappedValue.dismiss()", SESSION)
        self.assertNotIn('closeRequested = ideck_wineprocess_request_close()', SESSION)
        self.assertIn("coordinator.pollWindowsSessionClose()", SESSION)
        self.assertIn("coordinator.refreshWindowsSessionHealth()", SESSION)
        self.assertIn("coordinator.isClosingWindowsSession", SESSION)
        self.assertIn("Closing Wine and wineserver...", SESSION)

    def test_modal_remains_until_clean_shutdown_and_library_is_preserved(self):
        self.assertIn('coordinator.windowsStatus == "Closing Windows session..."', MAIN)
        self.assertIn('coordinator.windowsStatus != "Windows Ready"', MAIN)
        self.assertIn("coordinator.requestCloseWindowsSession()", MAIN)
        self.assertIn("GameSessionView(coordinator: coordinator)", MAIN)
        self.assertIn("selectedWorkspace == .pc", MAIN)
        self.assertNotIn("selectedWorkspace = nil", MAIN.split(".fullScreenCover(", 1)[1].split("private var homeView:", 1)[0])

    def test_coordinator_waits_for_both_threads_and_clears_session_state(self):
        self.assertIn("func requestCloseWindowsSession()", COORDINATOR)
        self.assertIn("func pollWindowsSessionClose()", COORDINATOR)
        self.assertIn("ideck_wineprocess_request_close()", COORDINATOR)
        self.assertIn("!ideck_wineprocess_running() && !ideck_wineserver_running()", COORDINATOR)
        self.assertIn("ideck_runtime_complete_session()", COORDINATOR)
        self.assertIn('setWindowsStatus("Windows Ready")', COORDINATOR)
        self.assertIn("activeSteamGameID = nil", COORDINATOR)
        self.assertIn("activeSteamPrefix = nil", COORDINATOR)
        self.assertIn("pendingSteamGameID = nil", COORDINATOR)

    def test_safe_failure_is_reported_without_killing_the_host(self):
        self.assertIn("seconds >= 15", COORDINATOR)
        self.assertIn("func retryCloseWindowsSession()", COORDINATOR)
        self.assertIn("func cancelWindowsSessionClose()", COORDINATOR)
        self.assertIn('Button(tr("Retry Close"))', SESSION)
        self.assertIn('Button(tr("Keep Waiting"))', SESSION)
        self.assertIn('Button(tr("Return to Game")', SESSION)
        for symbol in ("pthread_cancel(", "kill(getpid(", "\n    wineserver_stop();"):
            self.assertNotIn(symbol, BRIDGE)

    def test_native_session_is_rearmed_only_after_upstream_shutdown(self):
        self.assertIn("bool ideck_wineserver_running(void)", HEADER)
        self.assertIn('"wineserver_is_running"', SERVER)
        self.assertIn("bool ideck_runtime_complete_session(void)", HEADER)
        self.assertIn("!lock.owns_lock() || ideck_wineprocess_running() ||", BRIDGE)
        self.assertIn("ideck_wineserver_running() || !ideck_wineprocess_thread_finished()", BRIDGE)
        self.assertIn("ideck_wine_session_started = false", BRIDGE)
        self.assertIn("ideck_session_stop()", BRIDGE)
        self.assertIn('"MADEIRA_STEAM_APPID"', BRIDGE)
        self.assertIn('"MADEIRA_STEAM_APPPATH"', BRIDGE)
        self.assertIn('"MADEIRA_ENV_LOCKED"', BRIDGE)

    def test_guest_controller_observation_ends_with_session(self):
        self.assertIn("func stopBridging()", INPUT)
        self.assertIn("ideck_controller_stop()", INPUT)
        native_input = (ROOT / "iDeck/NativeRuntime/DirectInputBridge.mm").read_text(encoding="utf-8")
        self.assertIn("[center removeObserver:observer]", native_input)
        self.assertIn("WineInputBridge.shared.stopBridging()", SESSION)


if __name__ == "__main__":
    unittest.main()
