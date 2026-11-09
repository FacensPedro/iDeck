import unittest

from support import repo_text


class LaunchValidationTests(unittest.TestCase):
    def test_runtime_packages_are_verified(self):
        runtime = repo_text("iDeck/MadeiraRuntime.swift")
        for marker in ('"nls/locale.nls", "nls/l_intl.nls", "nls/normnfc.nls"', "ideck_native_pe_machine",
                       '"xtajit64"', '"winemetal"', '"d3d10core"', "manifestName(id)", "failed verification"):
            self.assertIn(marker, runtime)
        self.assertIn("if downloadsRuntime || FileManager.default.fileExists", runtime)
        split = repo_text("scripts/split_runtime_downloads.py")
        self.assertIn('f"ideck-runtime-{ident}.json"', split)

    def test_wine_never_starts_without_nls(self):
        windows = repo_text("iDeck/WindowsEnvironment.swift")
        self.assertIn("guard MadeiraRuntime.missingNLSFiles().isEmpty, MadeiraRuntime.installedProblems().isEmpty", windows)
        bridge = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
        self.assertIn('@"nls/locale.nls", @"nls/l_intl.nls", @"nls/normnfc.nls"', bridge)
        self.assertIn("if ([attributes fileSize] <= 0x1000) return ENOENT;", bridge)

    def test_ios_crash_diagnostics(self):
        diagnostics = repo_text("iDeck/IOSCrashDiagnostics.swift")
        self.assertIn("MXMetricManager.shared.add(self)", diagnostics)
        self.assertIn("crashDiagnostics", diagnostics)
        self.assertIn("IOSCrashDiagnostics.shared.start()", repo_text("iDeck/iDeckApp.swift"))
        report = repo_text("iDeck/BugReportView.swift")
        self.assertIn('lower.contains("wineserver crashed")', report)
        for informational in ('"[commit-zero]"', '"ml990:"', '"master_socket_timeout"'):
            self.assertIn(informational, report)
        self.assertIn("SystemCoordinator.lastLaunchJITKey", report)
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* IOSCrashDiagnostics.swift in Sources */"), 2)


if __name__ == "__main__":
    unittest.main()
