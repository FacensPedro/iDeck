import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PerGameJITPoolTests(unittest.TestCase):
    def test_profile_ui_and_session(self):
        models = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
        self.assertIn("static let jitPoolChoices = [0, 336, 448, 560, 624, 768]", models)
        self.assertIn("cpuCount, jitPoolMiB,", models)
        self.assertIn('DetailPickerRow(title: tr("JIT pool")', (ROOT / "iDeck/MainView.swift").read_text())
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn('lines.append("pool = \\(sessionJITPoolMiB)")', env)
        self.assertIn('MadeiraConfig.gameValue("pool")', (ROOT / "iDeck/MadeiraJIT/MadeiraWinePool.swift").read_text())


if __name__ == "__main__":
    unittest.main()
