import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GLUE = (ROOT / "iDeck/MadeiraDock/IDeckDockGlue.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
BUILD = (ROOT / "scripts/build_madeira_components.sh").read_text(encoding="utf-8")
STAGE = (ROOT / "scripts/stage_madeira_payload.sh").read_text(encoding="utf-8")

MEDIA = (
    "libavcodec-62.dll", "libavformat-62.dll", "libavutil-60.dll",
    "libavfilter-11.dll", "libswresample-6.dll", "libswscale-9.dll",
    "video64.dll",
)


class SteamDLLRecoveryTests(unittest.TestCase):
    def test_exact_video_dependencies_are_supported(self):
        for name in MEDIA:
            with self.subTest(name=name):
                self.assertIn('"' + name + '"', GLUE)
        self.assertIn('appendingPathComponent("SteamDLLs"', GLUE)
        self.assertIn('SteamRuntimeFiles.relativeRoot', GLUE)

    def test_media_group_and_sdl_architecture_are_checked_separately(self):
        self.assertIn('"SDL3.dll"', GLUE)
        self.assertIn('static let clientLibraries = mediaLibraries + [videoLibrary]', GLUE)
        self.assertIn('(clientLibraries + [sdlLibrary]).contains', GLUE)
        self.assertIn('static func steamClientMachine(root: URL) -> UInt16?', GLUE)
        self.assertIn('machine == 0x014c || machine == 0x8664', GLUE)
        self.assertIn('validDLL(input, machine: machine)', GLUE)
        self.assertIn('let sdl = repairSDL3(root: root, sourceFolder: folder, machine: machine)', GLUE)
        self.assertIn('prepared.count == clientLibraries.count', GLUE)
        self.assertIn('if invalidSources.isEmpty && invalidDestinations.isEmpty', GLUE)

    def test_never_replace_running_wine_or_unverified_media_dlls(self):
        self.assertIn('wine_process_is_running() == 0', GLUE)
        self.assertIn('wineserver_is_running() == 0', GLUE)
        self.assertIn('values.isRegularFile == true', GLUE)
        self.assertIn('values.isSymbolicLink != true', GLUE)
        self.assertIn('u16(pe + 4) == machine', GLUE)
        self.assertIn('u16(pe + 22) & 0x2000 != 0', GLUE)
        self.assertIn('u16(pe + 24) == magic', GLUE)
        self.assertIn('!fm.fileExists(atPath: destination.path)', GLUE)
        self.assertIn('try fm.copyItem(at: source, to: destination)', GLUE)
        self.assertNotIn('replaceItemAt(', GLUE)

    def test_sdl3_incompatible_repair_keeps_backup_and_rolls_back(self):
        self.assertIn('static func validX64DLL(_ url: URL) -> Bool', GLUE)
        self.assertIn('private static func repairSDL3(root: URL, sourceFolder: URL, machine: UInt16)', GLUE)
        self.assertIn('if validDLL(target, machine: machine) { return (false, nil) }', GLUE)
        self.assertIn('sdlLibrary + ".ideck-incompatible-backup"', GLUE)
        self.assertIn('try fm.moveItem(at: target, to: backup)', GLUE)
        self.assertIn('try fm.copyItem(at: input, to: target)', GLUE)
        self.assertIn('try? fm.moveItem(at: backup, to: target)', GLUE)
        self.assertIn('if let reason = sdl.invalid { invalid.append(reason) }', GLUE)

    def test_repair_off_ui_thread_and_no_graphics_reduction(self):
        self.assertIn('Task.detached(priority: .utility)', COORDINATOR)
        self.assertIn('SteamDLLRepair.repair(prefix: prefix)', COORDINATOR)
        self.assertIn('if !MadeiraDock.clientInstalled', COORDINATOR)
        self.assertIn('steamDLLAuditComplete = true', COORDINATOR)
        self.assertIn('SteamDLLRepair.hasImportFiles || !steamDLLAuditComplete', COORDINATOR)
        self.assertNotIn('resolution =', GLUE)
        self.assertNotIn('fpsMode =', GLUE)
        self.assertNotIn('metalFXEnabled =', GLUE)

    def test_security_modules_are_wine_arm64ec_not_downloaded_microsoft_binaries(self):
        for dll in ("msv1_0", "kerberos"):
            with self.subTest(module=dll):
                self.assertIn(f'dlls/$module/arm64ec-windows/$module.dll', BUILD)
                self.assertIn(f'arm64ec-windows/{dll}.dll', STAGE)
        self.assertNotIn('curl', BUILD.split('for module in msv1_0 kerberos', 1)[1].split('done', 1)[0])


if __name__ == "__main__":
    unittest.main()
