import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "iDeck/EALibrary.swift").read_text()


class EAHashCheckTests(unittest.TestCase):
    def test_check_recorded_and_reported(self):
        self.assertIn("EAHashCheck.report(profile: profile, hashVersion: activation.hashVersion, drive: Self.drive)", EA)
        self.assertIn('lines.append("EA hash check: " + check)', (ROOT / "iDeck/BugReportView.swift").read_text())

    def test_header_matches_wine_reg_escaping(self):
        # Wine writes section headers with doubled backslashes.
        self.assertIn('key.lowercased().replacingOccurrences(of: "\\\\", with: "\\\\\\\\")', EA)

    def test_reads_the_values_the_prefix_records(self):
        for name in ("ProductId", ".windows-serial"):
            self.assertIn(name, EA)
        # Hardware\\Description is volatile in Wine: never compared with system.reg.
        for name in ("BaseBoardManufacturer", "BIOSVendor", "ProcessorNameString", "MatchingDeviceId"):
            self.assertNotIn(name, EA)

    def test_report_shows_the_hashed_text(self):
        self.assertIn('let hashed = "hashed \\"" + profile.shownHashInput(version: hashVersion) + "\\""', EA)


if __name__ == "__main__":
    unittest.main()
