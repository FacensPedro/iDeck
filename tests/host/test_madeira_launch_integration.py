import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text(encoding="utf-8")
BRIDGE = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.h").read_text(encoding="utf-8")
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")


class MadeiraLaunchIntegrationTests(unittest.TestCase):
    def test_exit_codes_from_madeira(self):
        self.assertIn('"wine_process_exit_code"', BRIDGE)
        self.assertIn('"wine_crash_exit_status"', BRIDGE)
        self.assertIn("ideck_wineprocess_last_ntstatus", HEADER)
        self.assertIn("ideck_wineprocess_last_exit_code", HEADER)
        self.assertIn("WineExitDiagnostics.message", COORDINATOR)
        self.assertNotIn("Wine exited. The Windows program is no longer running.", COORDINATOR)

    def test_steam_app_identity(self):
        self.assertIn("steamAppID: game.appID", COORDINATOR)
        self.assertIn("steamInstallDirectory: directory", COORDINATOR)
        self.assertIn('launchDetails["steamAppID"]', ENVIRONMENT)
        self.assertIn('launchDetails["steamInstallDirectory"]', ENVIRONMENT)
        self.assertIn('request[@"steamAppID"]', NATIVE)
        self.assertIn('request[@"steamInstallDirectory"]', NATIVE)
        self.assertIn('setenv("MADEIRA_STEAM_APPID"', NATIVE)
        self.assertIn('setenv("MADEIRA_STEAM_APPPATH"', NATIVE)
        self.assertIn('request[@"steamWorkingDirectory"]', NATIVE)
        self.assertIn('setenv("MADEIRA_WORKDIR", windowsWorkingDirectory.UTF8String, 1)', NATIVE)
        self.assertIn('launchDetails["steamWorkingDirectory"]', ENVIRONMENT)
        self.assertIn("steamWorkingDirectory: selected.workingDirectory", COORDINATOR)
        self.assertIn('Steam working directory is missing or outside installed game', NATIVE)

        self.assertIn('unsetenv("MADEIRA_STEAM_APPID")', NATIVE)
        self.assertIn('unsetenv("MADEIRA_STEAM_APPPATH")', NATIVE)
        self.assertIn('setenv("MADEIRA_ENV_LOCKED"', NATIVE)
        self.assertIn('if ([request[@"isSteam"] boolValue] && steamID == nil)', NATIVE)
        self.assertNotIn('if ([request[@"isSteam"] boolValue] && steamID != nil) return EINVAL;', NATIVE)

    def test_native_launch_accepts_escaped_quoted_arguments(self):
        self.assertIn('ideck_quote_windows_argument((NSString *)arg)', NATIVE)
        self.assertIn(r'withString:@"\\"', NATIVE)
        self.assertIn('ideck_invalid_launch("invalid or oversized launch JSON")', NATIVE)
        self.assertIn('ideck_invalid_launch("invalid Steam app ID")', NATIVE)
        self.assertIn("if status == Int(EINVAL)", COORDINATOR)
        self.assertIn("[iDeck native launch] EINVAL", COORDINATOR)

    def test_windows_shell_pe_machine_and_precise_preflight(self):
        glue = (ROOT / "iDeck/MadeiraDock/IDeckDockGlue.swift").read_text(encoding="utf-8")
        self.assertIn("actualMachine == 0xA641", ENVIRONMENT)
        self.assertNotIn("actualMachine == 0xAA64", ENVIRONMENT)
        self.assertIn('drive_c/windows/system32/cmd.exe', ENVIRONMENT)
        self.assertIn('validCommandShell', glue)
        self.assertIn('machine == 0x8664 || machine == 0xA641', glue)
        self.assertIn('valid Windows cmd.exe unavailable; prerequisites remain pending', COORDINATOR)
        self.assertNotIn("MadeiraDock.skipInstalls(", COORDINATOR)
        self.assertNotIn("static func skipInstalls(", glue)
        self.assertIn('executable missing:', ENVIRONMENT)
        self.assertIn('executable is not a valid Windows PE:', ENVIRONMENT)
        self.assertIn('malformed or oversized Windows launch arguments', ENVIRONMENT)
        self.assertIn('unsupported Windows PE machine', ENVIRONMENT)
        self.assertIn('guestMachine == 0xa641', NATIVE)

    def test_do_not_disable_wine_directwrite(self):
        self.assertNotIn('setenv("WINEDLLOVERRIDES"', ENVIRONMENT)


if __name__ == "__main__":
    unittest.main()
