import unittest
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[2]
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

    def test_native_start_rejects_missing_jit_and_memory_permissions(self):
        source = (ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm").read_text()
        fex = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text()
        self.assertIn("if (!ideck_fex_jit_ready()) return EPERM;", source)
        self.assertIn("if (!ideck_wine_jit_pool_prepare() || !ideck_wine_jit_pool_ready()) return ENOMEM;", source)
        self.assertIn("vm_protect(", fex)
        self.assertNotIn("SecTaskCopyValueForEntitlement", source)
        self.assertNotIn("#import <Security/SecTask.h>", source)

    def test_signed_entitlements_must_be_verified_off_device(self):
        checker = (ROOT / "scripts/verify_signed_madeira_app.py").read_text()
        self.assertIn("codesign", checker)
        self.assertIn("embedded.mobileprovision", checker)
        self.assertIn("security", checker)
        for key in REQUIRED:
            self.assertIn(key, checker)


if __name__ == "__main__":
    unittest.main()
