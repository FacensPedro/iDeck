import unittest

from support import ROOT, repo_text


class Release17Tests(unittest.TestCase):
    def test_irelay_is_removed(self):
        for name in ("IRelayClient.swift", "IRelayDeviceService.swift"):
            self.assertFalse((ROOT / "iDeck" / name).exists())
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertNotIn("IRelay", project)
        for path in (ROOT / "iDeck").rglob("*.swift"):
            self.assertNotIn("IRelay", path.read_text(encoding="utf-8"), path.name)

    def test_download_speed_and_resumable_ea_pause(self):
        speed = repo_text("iDeck/DownloadSpeed.swift")
        for line in ("static let steamChunks = 16", "static let epicWindow = 32", "static let eaFiles = 8",
                     "static let eaSegments = 16", "static let eaConnections = 40", "static let gogFiles = 4",
                     "static let gogChunksPerFile = 3", "static let gogConnections = 12"):
            self.assertIn(line, speed)
        ea = repo_text("iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift")
        self.assertIn('".madeira-seg"', ea)
        self.assertIn("let pending = ranges.indices.filter { !finished.contains($0) }", ea)
        self.assertNotIn("defer { try? FileManager.default.removeItem(at: compressed) }", ea)
        self.assertIn("previous.state == .paused { download.progress = previous.progress }", repo_text("iDeck/EALibrary.swift"))

    def test_library_and_shelf_presentation(self):
        view = repo_text("iDeck/MainView.swift")
        self.assertIn("private static let uninstalledCoverBlur: CGFloat = 1.5", view)
        for gone in ("libraryHeading", "shelfProgress(", 'tr("Game Library")', "progressAction("):
            self.assertNotIn(gone, view)
        tile = view.split("private func shelfTile(_ item: ShelfItem)", 1)[1].split("private func shelfArtwork", 1)[0]
        self.assertNotIn("Text(shelfTitle(item))", tile)
        self.assertIn('Text(tr("Installed: %@", installedText))', view)
        self.assertEqual(view.count("installedBytesText(done:"), 4)

    def test_notifications_settings_and_launch(self):
        background = repo_text("iDeck/BackgroundDownloads.swift")
        self.assertIn("whenNotificationsAllowed {", background)
        self.assertIn("guard Self.notificationsEnabled, Self.notificationsAllowed == true else { return }", background)
        self.assertIn('title: tr("Setup assistant")', repo_text("iDeck/SettingsView.swift"))
        coordinator = repo_text("iDeck/SystemCoordinator.swift")
        self.assertIn("func prewarmJITForLaunch()", coordinator)
        self.assertEqual(repo_text("iDeck/MainView.swift").count("coordinator.prewarmJITForLaunch()"), 2)
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("MARKETING_VERSION = 1.8.0;"), 6)


class VulkanHostLibraryTests(unittest.TestCase):
    def test_moltenvk_is_read_from_the_app_bundle(self):
        script = repo_text("scripts/apply_madeira_runtime_root.py")
        self.assertIn('[bundle stringByAppendingPathComponent:@"gl/', script)
        self.assertIn('[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"gl/', script)
        self.assertIn("return status or host_libraries(Path(root))", script)


if __name__ == "__main__":
    unittest.main()
