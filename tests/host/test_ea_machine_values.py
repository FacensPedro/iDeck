"""The machine hash uses the values the game itself reads under Madeira."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FORMATS = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAFormats.swift").read_text()
API = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EAAPI.swift").read_text()
LICENSE = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EALicense.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()
PATCH = (ROOT / "patches/wine-ios-machine-identity.patch").read_text()
FETCH = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()


def volume_serial(base: int, letter: int) -> int:
    """ntdll's ios_wow_volume_serial: FNV-1a over the stored value and the drive letter."""
    if not base:
        return 0
    value = 2166136261
    for index in range(4):
        value ^= (base >> (index * 8)) & 0xFF
        value = (value * 16777619) & 0xFFFFFFFF
    value ^= letter
    value = (value * 16777619) & 0xFFFFFFFF
    return base if value in (0, 0xFFFFFFFF) else value

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

    def test_volume_serial_follows_ntdll(self):
        # Values from the C function compiled as it stands in dlls/ntdll/unix/file.c.
        self.assertEqual(volume_serial(0x12345678, ord("c")), 0x1D5B1F12)
        self.assertEqual(volume_serial(0x12345678, 0), 0xBC5A865F)
        self.assertEqual(volume_serial(0xDEADBEEF, ord("c")), 0x2D805578)
        self.assertEqual(volume_serial(0, ord("c")), 0)
        for line in ("var hash: UInt32 = 2_166_136_261", "hash = hash &* 16_777_619", "hash ^= UInt32(letter)",
                     "return hash == 0 || hash == UInt32.max ? base : hash",
                     'static let fileName = ".madeira-volume-serial"',
                     "UInt32(truncatingIfNeeded: strtoul(text, nil, 16))"):
            self.assertIn(line, FORMATS)
        self.assertIn('profile.volumeSerial = String(format: "%08x", serial)', API)
        # The file is written in ntdll's own form when the prefix has none.
        self.assertIn('String(format: "%08x\\n", base)', API)
        self.assertIn('prefix.path + "/dosdevices/" + String(UnicodeScalar(letter)) + ":"', API)

    def test_wine_gives_64_bit_programs_the_serial(self):
        self.assertIn("wine      wine   wine-ios-machine-identity.patch", (ROOT / "patches/series.txt").read_text())
        self.assertIn("-            if (NtCurrentTeb()->WowTebOffset && (info->VolumeSerialNumber = ios_wow_volume_serial( drive->letter )))", PATCH)
        self.assertIn("+            if ((info->VolumeSerialNumber = ios_wow_volume_serial( drive->letter )))", PATCH)
        self.assertIn("-            else if (NtCurrentTeb()->WowTebOffset)", PATCH)
        self.assertIn('ERR( "ios volume serial %08x for drive %c: (%s caller)\\n"', PATCH)
        self.assertIn('ERR( "ios smbios: %s (%s caller)\\n"', PATCH)
        # Only ntdll's Unix side, which iDeck builds from source.
        files = [line for line in PATCH.splitlines() if line.startswith("+++ ")]
        self.assertEqual(files, ["+++ b/dlls/ntdll/unix/file.c", "+++ b/dlls/ntdll/unix/system.c"])

    def test_install_date_from_stat_birth_time(self):
        self.assertIn("EAHardwareProfile.wmiDate(seconds: Int(folder.st_birthtimespec.tv_sec),", API)
        self.assertIn("static func wmiDate(seconds: Int, nanoseconds: Int) -> String {", FORMATS)
        self.assertIn("(nanoseconds / 1_000_000) * 1000", FORMATS)

    def test_wmi_queries_reach_the_log_and_the_report(self):
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_wmi_trace.py" "$DEST"', FETCH)
        overlay = (ROOT / "scripts/apply_madeira_wmi_trace.py").read_text()
        self.assertIn("trace+file,trace+wbemprox", overlay)
        self.assertIn("enum EAActivationTrace {", REPORT)
        for word in ('".dlf"', '"wbemprox"', '"[vgpu]"', '"ios volume serial"', '"ios smbios"'):
            self.assertIn(word, REPORT)
        # A licence file is named by digits: the trace does not fold numbers together.
        self.assertIn("seen.insert(key(lower)).inserted", REPORT)
        # Only a command line is searched for tokens.
        self.assertIn('lower.contains("trace:process") ? sanitized(line) : capped(line)', REPORT)

    def test_report_shows_licence_files_and_ea_logs(self):
        self.assertIn('lines.append("EA licence files: " + EAPrefixEvidence.licenceFiles(drive: EALibrary.drive))', REPORT)
        self.assertIn('static let logFolder = ["ProgramData", "Origin", "Logs"]', REPORT)
        self.assertIn('lines += text.suffix(linesPerFile).map { "  " + EAActivationTrace.sanitized($0) }', REPORT)

    def test_overlay_adds_the_channel_once(self):
        import importlib.util
        import tempfile

        spec = importlib.util.spec_from_file_location("wmi_trace", ROOT / "scripts/apply_madeira_wmi_trace.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "app/Madeira/WineProcessBridge.m"
            target.parent.mkdir(parents=True)
            target.write_text("    " + module.OLD + "\n")
            self.assertEqual(module.main(folder), 0)
            self.assertEqual(module.main(folder), 0)
            self.assertEqual(target.read_text().count("trace+wbemprox"), 1)
            target.write_text("nothing here\n")
            self.assertEqual(module.main(folder), 2)


if __name__ == "__main__":
    unittest.main()
