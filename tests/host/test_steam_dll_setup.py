"""The Madeira Dock step finishes and shows progress while it downloads."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
GLUE = (ROOT / "iDeck/MadeiraDock/IDeckDockGlue.swift").read_text()


class SteamDLLSetupTests(unittest.TestCase):
    def test_leftover_downloaded_dlls_do_not_start_the_setup_again(self):
        start = COORDINATOR.index("func installSteamClientComponentsIfNeeded(")
        body = COORDINATOR[start:COORDINATOR.index('steamComponentsProgress = "Installing Madeira Dock components…"', start)]
        self.assertNotIn("hasImportFiles", body)
        self.assertIn("guard !MadeiraDock.clientInstalled || SteamDLLRepair.needsRepair(prefix: MadeiraDock.prefix) else {", body)

    def test_a_running_setup_keeps_its_progress_line(self):
        start = COORDINATOR.index("func installSteamClientComponentsIfNeeded(")
        body = COORDINATOR[start:]
        self.assertLess(body.index("guard steamComponentsTask == nil else { return }"),
                        body.index('"Dock setup is unavailable while Wine is running'))

    def test_the_dll_download_reports_its_percentage(self):
        fetch = GLUE[GLUE.index("static func fetch(progress:"):]
        fetch = fetch[:fetch.index('await progress("Steam DLLs are ready.")')]
        self.assertIn("ObservedDownload.run(request, expected: Int64(package.bytes))", fetch)
        self.assertNotIn("session.download(from: url)", fetch)
        self.assertIn('progress("\\(label) \\(percent)%…")', fetch)
        # The checks on the result are kept.
        self.assertIn("http.url?.host == url.host, http.url?.scheme == \"https\"", fetch)
        self.assertIn("hash(archive) == package.sha256", fetch)


if __name__ == "__main__":
    unittest.main()
