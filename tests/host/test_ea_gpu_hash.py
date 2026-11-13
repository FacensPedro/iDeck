import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORMATS = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAFormats.swift").read_text()
API = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAAPI.swift").read_text()


def hashed_gpu(pnp: str, version: int) -> str:
    """EAHardwareProfile.hashedGPU: before version 4 up to the last backslash."""
    if not pnp:
        return "None"
    if version >= 4:
        return pnp
    cut = pnp.rfind("\\")
    return pnp if cut < 0 else pnp[:cut]


class EAGpuHashTests(unittest.TestCase):
    def test_pnp_id_matches_wine_hardware_id(self):
        # Wine 11's wbemprox answers Win32_VideoController.PNPDeviceID with the display
        # device's HardwareID, which win32u writes without an instance suffix.
        self.assertIn('var gpuPNPDeviceID = "PCI\\\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00"', FORMATS)
        self.assertNotIn('REV_00\\\\00000000"', FORMATS)
        self.assertIn('"PCI\\\\VEN_%04X&DEV_%04X&SUBSYS_00000000&REV_00", gpuVendor, gpuDevice)', API)

    def test_hash_cuts_before_version_4_only(self):
        self.assertIn("static func hashedGPU(_ pnpDeviceID: String, version: Int) -> String {", FORMATS)
        self.assertIn("guard version < 4 else { return pnpDeviceID }", FORMATS)
        self.assertIn("let gpu = Self.hashedGPU(gpuPNPDeviceID, version: version)", FORMATS)
        pnp = "PCI\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00"
        self.assertEqual(hashed_gpu(pnp, 2), "PCI")
        self.assertEqual(hashed_gpu(pnp, 3), "PCI")
        self.assertEqual(hashed_gpu(pnp, 4), pnp)
        self.assertEqual(hashed_gpu("", 2), "None")


if __name__ == "__main__":
    unittest.main()
