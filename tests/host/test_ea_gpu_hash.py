import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class EAGpuHashTests(unittest.TestCase):
    def test_pnp_id_matches_wine_hardware_id(self):
        # win32u writes the display device's HardwareID without the instance suffix,
        # and wbemprox returns it as Win32_VideoController.PNPDeviceID.
        formats = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAFormats.swift").read_text()
        api = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAAPI.swift").read_text()
        self.assertIn('var gpuPNPDeviceID = "PCI\\\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00"', formats)
        self.assertNotIn('REV_00\\\\00000000"', formats)
        self.assertIn('"PCI\\\\VEN_%04X&DEV_%04X&SUBSYS_00000000&REV_00", gpuVendor, gpuDevice)', api)

    def test_hash_takes_up_to_last_backslash(self):
        pnp = "PCI\\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00"
        self.assertEqual(pnp[:pnp.rfind("\\")], "PCI")


if __name__ == "__main__":
    unittest.main()
