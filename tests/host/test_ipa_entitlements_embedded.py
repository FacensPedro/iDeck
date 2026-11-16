"""The IPA carries its entitlements so sideloaders enable Memory+ on the App ID."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = (ROOT / "scripts/build_ipa.sh").read_text()


class EmbeddedEntitlementsTests(unittest.TestCase):
    def test_entitlements_are_embedded_before_packaging(self):
        self.assertIn('embed_entitlements "$APP/$APP_EXE" iDeck/iDeck.entitlements', BUILD)
        self.assertLess(BUILD.index('embed_entitlements "$APP/$APP_EXE"'), BUILD.index("scripts/package_ipa.py"))

    def test_extended_addressing_is_requested_and_checked(self):
        self.assertIn("com.apple.developer.kernel.extended-virtual-addressing",
                      (ROOT / "iDeck/iDeck.entitlements").read_text())
        self.assertIn("extended-virtual-addressing missing from", BUILD)


if __name__ == "__main__":
    unittest.main()
