"""Launchers install only from their button; the JIT pool is freed after each
session; programs an installer put in the prefix carry its shortcut's name and
icon, and the installer leaves the list once Wine has stopped."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def text(path):
    return (ROOT / path).read_text()


class LaunchersPoolAndInstalledProgramsTests(unittest.TestCase):
    def test_launchers_step_does_not_install_by_itself(self):
        view = text("iDeck/MainView.swift")
        step = view[view.index("private var launchersStep: some View"):view.index("// MARK: - JIT")]
        self.assertEqual(step.count("coordinator.installDefaultStoreClients()"), 1)
        self.assertNotIn("launchersRequested", view)
        self.assertNotIn("automatically, so their games can start", view)
        self.assertIn('Text(tr("Installing %@...", launchersInstalling))', step)
        self.assertNotIn("progressNote", step)

    def test_pool_is_released_when_a_session_ends(self):
        pool = text("iDeck/MadeiraJIT/MadeiraWinePool.swift")
        release = pool[pool.index("static func release() -> Int?"):]
        self.assertIn("StikJITHelper.discardPool(pool)", release)
        self.assertIn("for key in exports { unsetenv(key) }", release)
        self.assertIn("prepared = pool", pool)
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn("self.releaseJITPoolAfterSession()", coordinator)
        body = coordinator[coordinator.index("private func releaseJITPoolAfterSession("):]
        body = body[:body.index("private func previousWineSessionStillFinishing")]
        self.assertIn("guard WindowsEnvironment.sessionsThisRun > 0", body)
        self.assertLess(body.index("ideck_runtime_complete_session()"), body.index("MadeiraWinePool.release()"))

    def test_installed_programs_use_shortcut_name_and_icon(self):
        library = text("iDeck/WindowsLibraryModels.swift")
        self.assertIn("static func shortcuts(in drive: URL) -> [(exe: URL, name: String)]", library)
        self.assertIn("func displayName(for url: URL) -> String", library)
        self.assertIn("await self?.importEmbeddedIcon(for: executable)", library)
        view = text("iDeck/MainView.swift")
        self.assertIn("case .exe(let path): return windowsLibrary.displayName(for: URL(fileURLWithPath: path))", view)
        self.assertIn("library.profile(forExecutable: executableURL)", view)

    def test_installer_leaves_list_after_wine_stops(self):
        view = text("iDeck/MainView.swift")
        self.assertIn("while ended && ideck_wineprocess_running() && waited < 40", view)
        coordinator = text("iDeck/SystemCoordinator.swift")
        self.assertIn("if plan.kind != nil { WindowsLibraryStore.noteLaunch(of: url) }", coordinator)


if __name__ == "__main__":
    unittest.main()
