import unittest
from pathlib import Path

VIEW = (Path(__file__).resolve().parents[2] / "iDeck/MainView.swift").read_text()


class SetupTests(unittest.TestCase):
    def test_steps(self):
        self.assertIn("case visualCpp, wineMono, dock, jit, summary", VIEW)
        self.assertNotIn('statusRow("x64 Wine environment"', VIEW)

    def test_visual_cpp_installs_everything(self):
        block = VIEW[VIEW.index("private func installVisualCpp()"):VIEW.index("// MARK: - Madeira Dock")]
        self.assertIn("VisualCRuntimeBootstrap.download(in: MadeiraDock.prefix)", block)
        self.assertIn("VisualCRuntimeLegacy.installAll(documents: docs)", block)
        self.assertIn("coordinator.openMadeiraWorkspace()", block)

    def test_wine_mono_step(self):
        self.assertIn("wineMono.install()", VIEW)
        self.assertIn("(current == .wineMono && !wineMono.installed)", VIEW)


if __name__ == "__main__":
    unittest.main()
