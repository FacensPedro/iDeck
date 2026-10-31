import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SteamInstallProgressAccountingTests(unittest.TestCase):
    def test_installing_label_replaces_downloading_in_both_views(self):
        view = (ROOT / "iDeck/MainView.swift").read_text(encoding="utf-8")
        # Steam's card and game sheet, and the Epic and GOG cards.
        self.assertEqual(view.count('tr("Installing %d%%"'), 4)
        # Cards keep a fixed-height progress row; byte counts live in the game sheet.
        self.assertEqual(view.count('tr("Installed: %@"'), 1)
        self.assertIn("private func steamProgressAction(for game: SteamAppInfo)", view)
        self.assertIn(".frame(height: cardActionHeight)", view)
        self.assertNotIn('tr("Downloading %d%%"', view)
        self.assertNotIn('tr("Already on device: %@"', view)
        self.assertNotIn("progress.reusedBytes", view)
        self.assertIn("progress.installedBytes", view)
        self.assertIn("steamLibrary.installedSizes[game.appID]", view)

    def test_progress_tracks_uncompressed_verified_and_written_bytes(self):
        source = (ROOT / "iDeck/SteamDepotDownloader.swift").read_text(encoding="utf-8")
        self.assertIn("var installedBytes: UInt64 = 0", source)
        self.assertIn("state.installedBytes = prepared.installedBytes", source)
        self.assertIn("result.installedBytes += UInt64(chunk.uncompressedSize)", source)
        self.assertIn("state.installedBytes += UInt64(chunk.uncompressedSize)", source)
        self.assertIn("state.installedBytes += written", source)
        self.assertIn("SteamInstallFiles.logicalInstalledSize(at: installURL)", source)
        self.assertIn("Task.detached(priority: .utility", source)
        self.assertIn("state.reusedBytes += count", source)

    def test_game_size_scan_avoids_symlinks_and_runs_outside_main_actor(self):
        scanner = (ROOT / "iDeck/SteamInstall.swift").read_text(encoding="utf-8")
        model = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
        self.assertIn("nonisolated static func logicalInstalledSize(at folder: URL) -> UInt64?", scanner)
        self.assertIn("lstat(entry.path, &item) == 0", scanner)
        self.assertIn("directories.append(entry)", scanner)
        self.assertIn("type == mode_t(S_IFREG)", scanner)
        self.assertIn("bytes.addingReportingOverflow(UInt64(item.st_size))", scanner)
        self.assertIn("Task.detached(priority: .utility)", model)
        self.assertIn("installedSizeScanGeneration == generation", model)
        self.assertIn("installedSizes.removeValue(forKey: appID)", model)
        self.assertIn("installedSizes[appID] = measuredSize", model)

    def test_portuguese_and_spanish_install_labels(self):
        localization = (ROOT / "iDeck/Localization.swift").read_text(encoding="utf-8")
        self.assertIn('"Installed: %@": ["pt": "Instalado: %@", "es": "Instalado: %@"]', localization)
        self.assertIn('"Installing %d%%": ["pt": "Instalando %d%%", "es": "Instalando %d%%"]', localization)
        self.assertNotIn('"Already on device: %@"', localization)
        self.assertNotIn('"Downloading %d%%"', localization)

    def test_swift_host_suite_checks_real_install_size(self):
        fixture = (ROOT / "tests/host/SteamInstallLaunchPathTests.swift").read_text(encoding="utf-8")
        self.assertIn("SteamInstallFiles.logicalInstalledSize(at: installFolder) == 10_240", fixture)
        self.assertIn("4 * 1024 * 1024 * 1024 + 10_240", fixture)
        self.assertIn("createSymbolicLink", fixture)


if __name__ == "__main__":
    unittest.main()
