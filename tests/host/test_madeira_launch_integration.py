import unittest
from pathlib import Path

from support import ROOT, repo_text
NATIVE = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
BRIDGE = repo_text("iDeck/NativeRuntime/WineBridge.mm")
HEADER = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.h")
ENVIRONMENT = repo_text("iDeck/WindowsEnvironment.swift")
COORDINATOR = repo_text("iDeck/SystemCoordinator.swift")


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
        glue = repo_text("iDeck/MadeiraDock/IDeckDockGlue.swift")
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
