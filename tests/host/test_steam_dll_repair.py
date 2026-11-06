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
    "video64.dll", "SDL3.dll",
)


class SteamDLLRecoveryTests(unittest.TestCase):
    def test_exact_video_dependencies_are_supported(self):
        for name in MEDIA:
            with self.subTest(name=name):
                self.assertIn('"' + name + '"', GLUE)
        self.assertIn('appendingPathComponent("SteamDLLs"', GLUE)
        self.assertIn('SteamRuntimeFiles.relativeRoot', GLUE)

    def test_never_overwrite_active_or_untrusted_steam_installation(self):
        self.assertIn('wine_process_is_running() == 0', GLUE)
        self.assertIn('wineserver_is_running() == 0', GLUE)
        self.assertIn('values.isRegularFile == true', GLUE)
        self.assertIn('values.isSymbolicLink != true', GLUE)
        self.assertIn('u16(pe + 4) == 0x8664', GLUE)
        self.assertIn('u16(pe + 22) & 0x2000 != 0', GLUE)
        self.assertIn('let blocked = invalidExisting.filter { $0 != sdlLibrary }', GLUE)
        self.assertIn('let videoReady = videoLibraries.allSatisfy', GLUE)
        self.assertIn('if exists && name != sdlLibrary { continue }', GLUE)
        self.assertIn('name + ".ideck-invalid-backup"', GLUE)
        self.assertIn('try fm.copyItem(at: source, to: temporary)', GLUE)
        self.assertIn('try fm.moveItem(at: temporary, to: destination)', GLUE)
        self.assertIn('try? fm.moveItem(at: backup, to: destination)', GLUE)
        self.assertNotIn('replaceItemAt(', GLUE)

    def test_sdl_repair_is_separate_from_complete_ffmpeg_set(self):
        self.assertIn('static let sdlLibrary = "SDL3.dll"', GLUE)
        self.assertIn('let candidates = (videoReady ? videoLibraries : []) + [sdlLibrary]', GLUE)
        self.assertIn('u16(pe + 24) == 0x020b', GLUE)
        self.assertIn('u16(pe + 20) >= 112', GLUE)
        self.assertIn('validX64DLL(temporary)', GLUE)
        self.assertIn('SteamDLLRepair.repair(prefix: root)', COORDINATOR)
        self.assertIn('repaired before Steam launch:', COORDINATOR)
        self.assertIn('missing before launch:', COORDINATOR)

    def test_repair_off_ui_thread_and_no_graphics_reduction(self):
        self.assertIn('Task.detached(priority: .utility)', COORDINATOR)
        self.assertIn('SteamDLLRepair.repair(prefix: prefix)', COORDINATOR)
        self.assertIn('if !MadeiraDock.clientInstalled', COORDINATOR)
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
