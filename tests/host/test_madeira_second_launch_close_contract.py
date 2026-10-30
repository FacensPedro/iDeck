import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
PATCH = (ROOT / "patches/madeira-repeat-wine-sessions.patch").read_text()
BRIDGE = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text()


class MadeiraSecondLaunchCloseContractTests(unittest.TestCase):
    def test_every_launch_checks_previous_guest_completion_before_preparing_runtime(self):
        for method, next_method in (
            ("func launchSteam()", "private func withPreparedMetalDisplay("),
            ("func launchWindowsExecutable(", "/// Launches a Steam game"),
            ("func launchSteamGame(", "// A Windows guest runs as a thread"),
        ):
            with self.subTest(method=method):
                start = COORDINATOR.index(method)
                end = COORDINATOR.find(next_method, start)
                if end < 0:
                    end = len(COORDINATOR)
                body = COORDINATOR[start:end]
                self.assertIn("previousWineSessionStillFinishing()", body)
        self.assertIn("!ideck_wineprocess_running()", COORDINATOR)
        self.assertIn("ideck_wineserver_running() || !ideck_wineprocess_thread_finished()", COORDINATOR)
        self.assertIn("guard ideck_runtime_complete_session() else", COORDINATOR)

    def test_native_release_only_after_both_threads_quiescent(self):
        close = NATIVE.split('extern "C" bool ideck_runtime_complete_session(void)', 1)[1]
        for expected in ("std::try_to_lock", "ideck_wineprocess_running()",
                         "ideck_wineserver_running()", "!ideck_wineprocess_thread_finished()",
                         "ideck_wine_session_started = false",
                         '"MADEIRA_ENV_LOCKED"', '"MADEIRA_STEAM_APPID"',
                         '"MADEIRA_STEAM_APPPATH"', '"MADEIRA_WAIT_CHILDREN"',
                         "ideck_gamepad_end_session()"):
            self.assertIn(expected, close)
        self.assertIn("g_wine_thread_finished", PATCH)
        self.assertIn("g_wineserver_should_stop", PATCH)

    def test_graceful_close_is_real_alt_f4_not_forced_host_kill(self):
        self.assertIn("bool ideck_wineprocess_request_close(void)", BRIDGE)
        self.assertIn("post(0x12, 1)", BRIDGE)
        self.assertIn("post(0x73, 1)", BRIDGE)
        self.assertIn("post(0x73, 0)", BRIDGE)
        self.assertIn("post(0x12, 0)", BRIDGE)
        self.assertIn('windowsCloseAttempts < 3', COORDINATOR)
        self.assertIn('seconds >= 15', COORDINATOR)
        self.assertIn('func retryCloseWindowsSession()', COORDINATOR)
        for forbidden in ("kill(getpid()", "pthread_cancel(", "SIGKILL"):
            self.assertNotIn(forbidden, BRIDGE)
            self.assertNotIn(forbidden, COORDINATOR)

    def test_session_does_not_leave_steam_game_or_guest_active_after_clean_close(self):
        close = COORDINATOR.split("private func finishWindowsSessionCloseIfPossible()", 1)[1]
        self.assertIn("guard !ideck_wineprocess_running(), !ideck_wineserver_running()", close)
        self.assertIn("ideck_wineprocess_thread_finished()", close)
        self.assertIn("ideck_runtime_complete_session()", close)
        self.assertIn("activeSteamGameID = nil", close)
        self.assertIn("activeSteamPrefix = nil", close)
        self.assertIn("pendingSteamGameID = nil", close)
        self.assertIn('setWindowsStatus("Windows Ready")', close)


if __name__ == "__main__":
    unittest.main()
