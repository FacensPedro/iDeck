import unittest

from support import repo_text


class UniversalInstallerEnvironmentTests(unittest.TestCase):
    def test_installer_technologies_and_switches(self):
        env = repo_text("iDeck/WindowsInstallerEnvironment.swift")
        for marker in ("0xd0, 0xcf, 0x11, 0xe0", '"Inno Setup Setup Data"', '"NullsoftInst"', '"InstallShield"',
                       '".wixburn"', "0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c", '"SquirrelSetup"'):
            self.assertIn(marker, env)
        self.assertIn('drive_c/windows/system32/msiexec.exe', env)
        self.assertIn('"/i \\"\\(path)\\" "', env)
        self.assertIn('"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"', env)

    def test_requirements_come_from_pe_imports(self):
        env = repo_text("iDeck/WindowsInstallerEnvironment.swift")
        self.assertIn("let delayDir = directory(13)", env)
        self.assertIn("let clr = directory(14)", env)
        self.assertIn('pe.imports.contains("mscoree.dll")', env)
        self.assertIn('$0.hasPrefix("vcruntime140")', env)
        for version in ('("80", "2005")', '("120", "2013")'):
            self.assertIn(version, env)

    def test_launches_go_through_the_environment(self):
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertIn("func launchWindowsProgram(at url: URL", coordinator)
        self.assertIn("prepareVisualCRuntimeIfNeeded(prefix: prefix, executable: destination", coordinator)
        self.assertIn("prepareVisualCRuntimeIfNeeded(prefix: prefixPath, executable: executableURL", coordinator)
        library = repo_text("iDeck/WindowsLibraryModels.swift")
        self.assertIn('fileExtension == "exe" || fileExtension == "msi"', library)
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* WindowsInstallerEnvironment.swift in Sources */"), 2)


if __name__ == "__main__":
    unittest.main()
