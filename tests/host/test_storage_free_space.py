import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class StorageFreeSpaceTests(unittest.TestCase):
    def test_free_space_section(self):
        settings = (ROOT / "iDeck/SettingsView.swift").read_text()
        self.assertIn('Section(tr("Free space"))', settings)
        self.assertIn("externalDrives.capacity(folder)", settings)
        drives = (ROOT / "iDeck/ExternalDrives.swift").read_text()
        self.assertIn("static func capacity(of url: URL) -> (free: Int64, total: Int64)?", drives)


    def test_session_memory_sampling(self):
        coord = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn("private func startMemorySampling(launcher: String)", coord)
        report = (ROOT / "iDeck/BugReportView.swift").read_text()
        self.assertIn('"[memory] session"', report)
        self.assertIn("diagnostics.contains(where: lower.contains)", report)


if __name__ == "__main__":
    unittest.main()
