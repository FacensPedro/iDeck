"""Regression coverage for audited IPA security receipts and JIT source integrity."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
AUDITOR = ROOT / "scripts/audit_ipa_distribution.py"
WORKFLOW = ROOT / ".github/workflows/ios.yml"
SPEC = importlib.util.spec_from_file_location("ideck_ipa_auditor", AUDITOR)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class DistributionAuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sources = self.root / "sources"
        for source in audit.EXPECTED_JIT.values():
            target = self.sources / source
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("JIT reviewed source: " + source, encoding="utf-8")
        self.ipa = self.root / "iDeck.ipa"

    def make_ipa(self, alter=None):
        entries = {
            "Payload/iDeck.app/Info.plist": plistlib.dumps({"CFBundleIdentifier": "org.ideck.test"}),
        }
        for dest, source in audit.EXPECTED_JIT.items():
            entries[dest] = (self.sources / source).read_bytes()
        entries.update(alter or {})
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for name, content in entries.items():
                archive.writestr(name, content)

    def test_valid_script_receipts_and_hash(self):
        self.make_ipa({"Payload/iDeck.app/Plugins/extra.js": b"console.log('review');"})
        report = audit.inspect_ipa(self.ipa, self.sources)
        self.assertEqual(report["archive_sha256"], audit.hash_file(self.ipa))
        self.assertEqual(len(report["verified_jit_scripts"]), 1)
        self.assertEqual(len(report["embedded_script_inventory"]), 2)
        self.assertEqual(report["security_verdict"].split(";")[0], "NOT_SCANNED")
        self.assertEqual(report["embedded_script_inventory"][1]["review"],
                         "matches-repository-source")

    def test_rejects_modified_jit_script(self):
        self.make_ipa({"Payload/iDeck.app/universal.jitscript": b"modified"})
        with self.assertRaisesRegex(ValueError, "differs from reviewed source"):
            audit.inspect_ipa(self.ipa, self.sources)

    def test_rejects_path_traversal_and_duplicate_entries(self):
        self.make_ipa({"Payload/iDeck.app/../evil.ps1": b"x"})
        with self.assertRaisesRegex(ValueError, "Unsafe or unexpected"):
            audit.inspect_ipa(self.ipa, self.sources)
        self.make_ipa()
        with zipfile.ZipFile(self.ipa, "a") as archive:
            archive.writestr("Payload/iDeck.app/universal.jitscript", b"second")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            audit.inspect_ipa(self.ipa, self.sources)

    def test_rejects_missing_jit_and_invalid_ipa(self):
        self.make_ipa()
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/iDeck.app/Info.plist", b"plist")
        with self.assertRaisesRegex(ValueError, "missing the verified"):
            audit.inspect_ipa(self.ipa, self.sources)
        self.ipa.write_bytes(b"fake IPA")
        with self.assertRaisesRegex(ValueError, "Not a valid"):
            audit.inspect_ipa(self.ipa, self.sources)

    def test_github_release_has_independent_security_receipts(self):
        flow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("python3 scripts/audit_ipa_distribution.py --ipa iDeck.ipa", flow)
        self.assertIn("iDeck-distribution-audit.json", flow)
        self.assertIn("iDeck.ipa.sha256", flow)
        self.assertIn("iDeck-security-receipts", flow)
        self.assertIn("gh release upload", flow)
        self.assertIn("gh release create", flow)
        self.assertIn("test_ipa_distribution_audit.py", flow)


if __name__ == "__main__":
    unittest.main()
