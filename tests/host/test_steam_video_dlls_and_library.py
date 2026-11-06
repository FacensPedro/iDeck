import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class SteamVideoDLLsAndLibraryTests(unittest.TestCase):
    def test_official_x64_video_packages_are_pinned(self):
        runtime = source("iDeck/MadeiraDock/SteamRuntime.swift")
        self.assertIn("bins_codecs_win64.zip.ad3f4b232ba00296ed683021adf1b761a629b74a", runtime)
        self.assertIn("160c767800a310521a9926771c85a07ab4d71bd4b621d2d11c4dbbf63449447f", runtime)
        self.assertIn("bins_win64.zip.1f91da2609327de9658146b01307e89a13cc1ef8", runtime)
        self.assertIn("f34b0d5924d0cca4c81775ed2fef0aee1ca060e2daa5c24270711267786c0236", runtime)
        self.assertIn("func fetchVideoLibraries(", runtime)
        coordinator = source("iDeck/SystemCoordinator.swift")
        self.assertIn("SteamDLLRepair.needsRepair(prefix:", coordinator)
        self.assertIn("fetchVideoLibraries", coordinator)

    def test_wine_mono_installer_matches_pinned_madeira(self):
        mono = source("iDeck/WineMono.swift")
        self.assertIn('static let tarSHA256 = "0cd723aa28897f7d7d2702eed6c72e4262255980e212bc2b3c94bfa234abe5fd"', mono)
        self.assertIn('appendingPathComponent("WineMono", isDirectory: true)', mono)
        self.assertIn("WineMono.swift in Sources", source("iDeck.xcodeproj/project.pbxproj"))

    def test_library_cards_follow_madeira(self):
        view = source("iDeck/MainView.swift")
        self.assertIn("aspectRatio(2.0 / 3.0, contentMode: .fit)", view)
        self.assertIn("GridItem(.adaptive(minimum: isCompact ? 110 : 154, maximum: 220), spacing: 20)", view)
        self.assertIn("LazyVGrid(columns: columns, spacing: 18)", view)
        self.assertNotIn("artworkHeight", view)

    def test_launcher_logos_have_no_tile_background(self):
        settings = source("iDeck/SettingsView.swift")
        self.assertIn("assetKeepsColors ? Color.clear : color", settings)
        self.assertIn('Image(slug == "ea" ? "StoreBadgeEA" : "StoreBadgeUbisoft")', settings)


if __name__ == "__main__":
    unittest.main()
