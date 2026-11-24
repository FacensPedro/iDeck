import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "iDeck/EALibrary.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()


class EAActivationLogTests(unittest.TestCase):
    def test_activation_window_reason_goes_to_the_app_log(self):
        self.assertIn("EAPrefixEvidence.activationReason(", EA)
        self.assertIn('"[ea-activation-log] "', EA)

    def test_personal_data_is_removed(self):
        self.assertIn("static func activationReason(drive: URL, hidden: [String]", REPORT)
        self.assertIn('"<ip>"', REPORT)
        self.assertIn('"<account>"', REPORT)
        self.assertIn("account?.displayName, account?.userID, account?.personaID", EA)

    def test_bug_report_keeps_the_lines(self):
        self.assertIn('"[ea-activation-log]"', REPORT)


if __name__ == "__main__":
    unittest.main()


class EALicenceOriginCacheTests(unittest.TestCase):
    def test_licence_also_in_origin_cache_and_logged(self):
        lic = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EALicense.swift").read_text()
        self.assertIn('drive.appendingPathComponent("ProgramData/Origin/LicenseCache")', lic)
        self.assertIn("licence-hash=", lic)
