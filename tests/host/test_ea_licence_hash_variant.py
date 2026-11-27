import split_sources  # noqa: F401  (iDeck 3.0 split files)
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "iDeck/EALibrary.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class EALicenceHashVariantTests(unittest.TestCase):
    def test_variant_drops_the_adapter_from_the_licence_hash_only(self):
        self.assertIn('if variant == 1 { licenceProfile.gpuPNPDeviceID = "" }', EA)
        self.assertIn("licenceProfile.machineHash(version: activation.hashVersion)", EA)
        self.assertIn("profile: licenceProfile, activation: activation", EA)

    def test_variant_flips_after_activationui(self):
        self.assertIn("let next = variant == 0 ? 1 : 0", EA)
        self.assertIn('EALibrary.noteSessionEnded(activationUI: Self.sessionLogContains(["activationui.exe"]', COORD)


if __name__ == "__main__":
    unittest.main()
