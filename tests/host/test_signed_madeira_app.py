import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "signed_madeira", ROOT / "scripts/verify_signed_madeira_app.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SignedMadeiraAppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "iDeck.app"
        self.app.mkdir()
        self.entitlements = {
            **dict.fromkeys(module.REQUIRED_ENTITLEMENTS, True),
            "application-identifier": "MYTEAMID.com.ideck.ideck",
        }
        self.profile_entitlements = {
            **self.entitlements,
            "com.apple.developer.team-identifier": "MYTEAMID",
            "application-identifier": "MYTEAMID.com.ideck.ideck",
        }
        self.profile = {
            "Entitlements": self.profile_entitlements,
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
        }
        self.manifest = {
            "fexInProcess": True, "wineInProcess": True,
            "dxmtLinked": True, "d3d12Linked": True,
            "graphicsBackend": "d3d12",
        }
        for rel in (
            "iDeck", "embedded.mobileprovision",
            "d3d12/libmetalirconverter.dylib",
            "MadeiraRuntime/d3d12/libmetalirconverter.dylib",
        ):
            file = self.app / rel
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"REAL SIGNATURE TEST INPUT")
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.ideck.ideck"}, stream)
        self.write_manifest()

    def write_manifest(self):
        with (self.app / "MadeiraRuntimeManifest.plist").open("wb") as stream:
            plistlib.dump(self.manifest, stream)

    def mocked_command(self, *args):
        if args[:2] == ("codesign", "-dvv"):
            return subprocess.CompletedProcess(args, 0, b"",
                b"Authority=Apple Development\nTeamIdentifier=MYTEAMID\n")
        if args[:3] == ("codesign", "-d", "--entitlements"):
            return subprocess.CompletedProcess(
                args, 0, plistlib.dumps(self.entitlements), b""
            )
        if args[:3] == ("security", "cms", "-D"):
            return subprocess.CompletedProcess(
                args, 0, plistlib.dumps(self.profile), b""
            )
        return subprocess.CompletedProcess(args, 0, b"", b"")

    def run_check(self):
        with patch.object(module, "command", side_effect=self.mocked_command):
            module.verify(self.app)

    def test_complete_signed_provisioning_is_accepted_without_modification(self):
        before = {
            file.relative_to(self.app): file.read_bytes()
            for file in self.app.rglob("*") if file.is_file()
        }
        self.run_check()
        after = {
            file.relative_to(self.app): file.read_bytes()
            for file in self.app.rglob("*") if file.is_file()
        }
        self.assertEqual(before, after)

    def test_signed_d3d11_does_not_require_or_bundle_apple_converter(self):
        self.manifest["graphicsBackend"] = "d3d11"
        self.manifest["d3d12Linked"] = False
        self.write_manifest()
        (self.app / "d3d12/libmetalirconverter.dylib").unlink()
        (self.app / "MadeiraRuntime/d3d12/libmetalirconverter.dylib").unlink()
        self.run_check()

    def test_d3d11_rejects_converter_leak(self):
        self.manifest["graphicsBackend"] = "d3d11"
        self.manifest["d3d12Linked"] = False
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "proprietary Metal Shader Converter"):
            self.run_check()

    def test_missing_signed_entitlement_is_rejected(self):
        self.entitlements.pop(module.REQUIRED_ENTITLEMENTS[1])
        with self.assertRaisesRegex(ValueError, "missing signed entitlement"):
            self.run_check()

    def test_entitlement_not_authorized_by_profile_is_rejected(self):
        self.profile_entitlements.pop(module.REQUIRED_ENTITLEMENTS[0])
        with self.assertRaisesRegex(ValueError, "does not authorize"):
            self.run_check()

    def test_wrong_signed_app_identifier_is_rejected(self):
        self.entitlements["application-identifier"] = "MYTEAMID.other.app"
        with self.assertRaisesRegex(ValueError, "signature does not identify"):
            self.run_check()

    def test_wrong_provisioned_app_identifier_is_rejected(self):
        self.profile_entitlements["application-identifier"] = "MYTEAMID.other.app"
        with self.assertRaisesRegex(ValueError, "does not authorize app ID"):
            self.run_check()

    def test_expired_profile_is_rejected(self):
        self.profile["ExpirationDate"] = datetime.now(timezone.utc) - timedelta(days=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.run_check()

    def test_missing_native_manifest_is_rejected(self):
        self.manifest["wineInProcess"] = False
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "wineInProcess"):
            self.run_check()

    def test_missing_converter_dylib_is_rejected(self):
        (self.app / "d3d12/libmetalirconverter.dylib").unlink()
        with self.assertRaisesRegex(ValueError, "missing signed native app input"):
            self.run_check()


if __name__ == "__main__":
    unittest.main()
