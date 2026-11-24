import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SESSION = (ROOT / "iDeck/GameSessionView.swift").read_text()
GUARD = (ROOT / "iDeck/SessionCompatibility.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
ENV = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()


class RuntimeGraphicsTests(unittest.TestCase):
    def test_hud_shows_ram(self):
        self.assertIn('Text("GPU memory: \\(metrics.gpuMemory)  RAM: \\(metrics.ram)")', SESSION)
        self.assertIn("ResourceGovernor.footprintMiB()", SESSION)

    def test_gpu_fault_markers(self):
        for marker in ['"command buffer ended in error"', '"caused gpu hang"', '"submissionsignored"']:
            self.assertIn(marker, GUARD)

    def test_gpu_fault_lightens_the_game(self):
        self.assertIn("GPUFaultGuard.note(endedGame, faulted: faulted)", COORD)
        self.assertIn("profile.metalFXEnabled = false", COORD)
        self.assertIn("profile.frameGeneration = false", COORD)
        self.assertIn("GPUFaultGuard.faulted(profile.id)", ENV)


if __name__ == "__main__":
    unittest.main()
