import unittest
from pathlib import Path
import plistlib

from support import ROOT, repo_text
REQUIRED = (
    "com.apple.developer.kernel.increased-memory-limit",
    "com.apple.developer.kernel.extended-virtual-addressing",
)


class MadeiraEntitlementTests(unittest.TestCase):
    def test_app_requests_both_memory_entitlements(self):
        with (ROOT / "iDeck/iDeck.entitlements").open("rb") as handle:
            entitlements = plistlib.load(handle)
        for key in REQUIRED:
            self.assertIs(entitlements.get(key), True)

    def test_signed_entitlements_must_be_verified_off_device(self):
        checker = repo_text("scripts/verify_signed_madeira_app.py")
        self.assertIn("codesign", checker)
        self.assertIn("embedded.mobileprovision", checker)
        self.assertIn("security", checker)
        for key in REQUIRED:
            self.assertIn(key, checker)


if __name__ == "__main__":
    unittest.main()
