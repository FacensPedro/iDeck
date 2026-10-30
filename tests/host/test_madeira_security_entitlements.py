import unittest
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = (
    "com.apple.developer.kernel.increased-memory-limit",
    "com.apple.developer.kernel.extended-virtual-addressing",
)


class MadeiraEntitlementTests(unittest.TestCase):
    def test_xcode_entitlements_request_both_memory_capabilities(self):
        with (ROOT / "iDeck/iDeck.entitlements").open("rb") as handle:
            entitlements = plistlib.load(handle)
        for key in REQUIRED:
            self.assertIs(entitlements.get(key), True)

    def test_native_runtime_checks_actual_signed_entitlements(self):
        source = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
        self.assertIn('#import <Security/SecTask.h>', source)
        self.assertIn("SecTaskCreateFromSelf", source)
        self.assertIn("SecTaskCopyValueForEntitlement", source)
        self.assertIn("if (value != kCFBooleanTrue)", source)
        for key in REQUIRED:
            self.assertIn(key, source)
        guard = "if (!ideck_required_memory_entitlements_granted()) return EPERM;"
        self.assertIn(guard, source)
        self.assertLess(source.index(guard), source.index("ideck_fex_initialize()"))

    def test_security_framework_is_linked_only_in_native_path(self):
        script = (ROOT / "scripts/link_madeira_native.sh").read_text()
        self.assertIn("-framework Security", script)
        release = (ROOT / "scripts/verify_signed_madeira_app.py").read_text()
        self.assertIn("codesign", release)
        self.assertIn("embedded.mobileprovision", release)


if __name__ == "__main__":
    unittest.main()
