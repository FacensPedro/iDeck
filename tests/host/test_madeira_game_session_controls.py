import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
VIEW = (ROOT / "iDeck/GameSessionView.swift").read_text(encoding="utf-8")
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
INPUT = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")
PROFILE = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text(encoding="utf-8")
ENT = (ROOT / "iDeck/iDeck.entitlements").read_text(encoding="utf-8")


class MadeiraGameSessionControls(unittest.TestCase):
    def test_graceful_close_from_visible_x(self):
        self.assertIn("coordinator.closeWindowsSession()", VIEW)
        self.assertIn('dlsym(RTLD_DEFAULT, "winios_post_key")', INPUT)
        self.assertIn("post(0x12, 1)", INPUT)
        self.assertIn("post(0x73, 1)", INPUT)
        self.assertIn("post(0x73, 0)", INPUT)
        self.assertIn("ideck_wineprocess_request_close", HEADER)
        self.assertIn("wineCloseRequested", COORD)

    def test_one_session_per_process(self):
        self.assertIn("ideck_wineprocess_session_used", INPUT)
        self.assertIn("ideck_wineprocess_session_used", COORD)
        self.assertIn("ideck_wineprocess_session_used", NATIVE)

    def test_profile_options_default_off(self):
        self.assertIn("var launchInDesktop: Bool = false", PROFILE)
        self.assertIn("var waitForChildProcesses: Bool = false", PROFILE)
        self.assertIn("decodeIfPresent(Bool.self, forKey: .launchInDesktop) ?? false", PROFILE)
        self.assertIn("decodeIfPresent(Bool.self, forKey: .waitForChildProcesses) ?? false", PROFILE)
        self.assertIn('setenv("MADEIRA_DESKTOP", "1"', NATIVE)
        self.assertIn('setenv("MADEIRA_WAIT_CHILDREN", "1"', NATIVE)
        self.assertIn('unsetenv("MADEIRA_WAIT_CHILDREN")', NATIVE)

    def test_memory_entitlement_is_requested(self):
        self.assertIn("<key>com.apple.developer.kernel.increased-memory-limit</key>", ENT)

if __name__ == "__main__":
    unittest.main()
