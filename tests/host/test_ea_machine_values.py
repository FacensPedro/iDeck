"""The machine hash uses the values the game itself reads under Madeira."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORMATS = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAFormats.swift").read_text()
API = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAAPI.swift").read_text()
LICENSE = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EALicense.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()

# FEXCore CPUID.cpp, Function_01h: the EDX bits FEX sets (Self Snoop and HTT clear).
FEX_EDX_BITS = [0, 1, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 19, 23, 24, 25, 26, 29]
# ECX with AES, PCLMULQDQ and SSE4.2 (CRC) on, AVX off, the hypervisor bit set.
FEX_ECX_BITS = [0, 1, 2, 3, 8, 9, 13, 19, 20, 22, 23, 25, 31]


class EAMachineValuesTests(unittest.TestCase):
    def test_cpuid_edx_is_fex_value(self):
        self.assertEqual(sum(1 << bit for bit in FEX_EDX_BITS), 0x278BFBF3)
        self.assertIn("var cpuEDX: UInt32 = 0x278B_FBF3", FORMATS)
        self.assertNotIn("0x2F8B_FBF3", FORMATS)

    def test_cpuid_ecx_is_fex_value(self):
        self.assertEqual(sum(1 << bit for bit in FEX_ECX_BITS), 0x82D8230F)
        self.assertIn("var cpuECX: UInt32 = 0x82D8_230F", FORMATS)

    def test_board_and_bios_read_from_iokit_as_wine_does(self):
        self.assertIn("enum EAPlatformIdentity {", API)
        self.assertIn("if let platform = EAPlatformIdentity.read() {", API)
        for name in ('"IOPlatformExpertDevice"', '"AppleSMBIOS"', 'stringValue("manufacturer")', 'stringValue("IOPlatformSerialNumber")',
                     '"IOServiceGetMatchingService"', '"IORegistryEntryCreateCFProperty"', '"IOObjectRelease"'):
            self.assertIn(name, API)
        # wbemprox's answers for a field missing from the SMBIOS table.
        self.assertIn('Values(boardManufacturer: "Intel Corporation", biosManufacturer: "The Wine Project", boardSerial: "None")', API)
        # Without IOPlatformExpertDevice Wine has no table at all.
        self.assertIn("guard expert != 0 else { return wbemDefaults }", API)

    def test_serial_number_kept_out_of_logs(self):
        self.assertIn("func shownHashInput(version: Int) -> String {", FORMATS)
        self.assertIn('input.replacingOccurrences(of: boardSerial, with: "<serial>")', FORMATS)
        self.assertIn("profile.shownHashInput(version: activation.hashVersion)", LICENSE)

    def test_ea_lines_kept_in_bug_report(self):
        self.assertIn('"[ea-service]", "[ea-license]"]', REPORT)


if __name__ == "__main__":
    unittest.main()
