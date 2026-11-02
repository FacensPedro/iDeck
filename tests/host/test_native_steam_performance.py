import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class SteamNativeMigrationTests(unittest.TestCase):
    def test_c_sources_are_in_real_app_build(self):
        project = read("iDeck.xcodeproj/project.pbxproj")
        for name in ("SteamNativeCore.c", "WineLogTriage.c"):
            with self.subTest(name=name):
                self.assertEqual(project.count(f"/* {name} in Sources */,"), 1)
                self.assertIn(f"/* {name} */ = {{isa = PBXFileReference;", project)
        bridge = read("iDeck/iDeck-Bridging-Header.h")
        self.assertIn('#import "SteamNativeCore.h"', bridge)
        self.assertIn('#import "NativeRuntime/WineLogTriage.h"', bridge)

    def test_madeira_style_diagnostics_do_not_parse_large_logs_on_refresh(self):
        native = read("iDeck/NativeRuntime/WineLogTriage.c")
        view = read("iDeck/GameSessionView.swift")
        self.assertIn("WINE_LOG_TAIL_LIMIT = 512 * 1024", native)
        self.assertIn("O_NOFOLLOW", native)
        self.assertIn("ideck_wine_log_diagnose($0)", view)
        self.assertIn(".onChange(of: coordinator.windowsStatus)", view)
        self.assertNotIn("updateRecentWineLogFinding()", view.split(".onReceive(tick)", 1)[1])


if __name__ == "__main__":
    unittest.main()
