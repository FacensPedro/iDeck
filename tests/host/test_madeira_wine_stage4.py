import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "wine_stage4", ROOT / "scripts/verify_madeira_wine_stage4.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MadeiraWineStage4Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

        paths = {
            "wine/VERSION": module.WINE_VERSION + "\n",
            module.BUILD_CONFIG: "ac_cs_config='--enable-archs=arm64ec --without-x --disable-tests'\n" + "Wine build\n" * 12,
            module.NATIVE_CONFIG: "#define HAVE_CONFIG_H 1\n" * 16,
            module.SERVER_BUILDER: "#!/usr/bin/env bash\nSERVER_SOURCES=(\n    file.c\n)\n",
        }
        for tree in ("wine/build-macos", "wine/build-arm64ec"):
            for header in module.GENERATED_HEADERS:
                paths[f"{tree}/include/{header}"] = "// Generated Wine SDK header\n" * 8

        for path, content in paths.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")

        for path in module.ARTIFACTS:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"compiled archive or PE" * 256)

    def test_valid_build_has_sha256_receipt_and_no_runtime_claims(self):
        with patch.object(module.compiled, "verify", return_value=[]):
            issues, receipt = module.verify(self.root, "a" * 40)
        self.assertEqual(issues, [])
        self.assertEqual(receipt["stage"], 4)
        self.assertEqual(receipt["wine_version"], "Wine version 11.4")
        self.assertEqual(len(receipt["artifact_hashes"]), len(module.ARTIFACTS))
        self.assertTrue(receipt["validated"])
        self.assertIn("Wine PE process starts on an iPad", receipt["not_validated"])

    def test_wrong_wine_version_fails_closed(self):
        (self.root / "wine/VERSION").write_text("Wine version 11.5\n")
        with patch.object(module.compiled, "verify", return_value=[]):
            issues, receipt = module.verify(self.root, "b" * 40)
        self.assertTrue(any("Wine version 11.4" in issue for issue in issues))
        self.assertFalse(receipt["validated"])

    def test_non_arm64ec_wine_configure_is_rejected(self):
        path = self.root / module.BUILD_CONFIG
        path.write_text(path.read_text().replace("--enable-archs=arm64ec", "--enable-archs=aarch64"))
        self.assertTrue(any("not configured for ARM64EC" in s for s in module.inspect_sources(self.root)))

    def test_generated_wine_headers_must_be_in_both_build_trees(self):
        missing = self.root / "wine/build-arm64ec/include/dwrite_3.h"
        missing.unlink()
        self.assertTrue(any("dwrite_3.h" in s for s in module.inspect_sources(self.root)))

    def test_wineserver_must_have_source_build_recipe(self):
        script = self.root / module.SERVER_BUILDER
        script.write_text("#!/bin/sh\ncp prebuilt.a libwineserver.a\n")
        self.assertTrue(any("source-build inputs" in s or "rebuilt from published sources" in s
                            for s in module.inspect_sources(self.root)))

    def test_missing_real_archive_cannot_be_reported_as_pass(self):
        (self.root / module.ARTIFACTS[-1]).unlink()
        with patch.object(module.compiled, "verify", return_value=[]):
            issues, receipt = module.verify(self.root, "c" * 40)
        self.assertTrue(any("artifact missing" in s for s in issues))
        self.assertFalse(receipt["validated"])

    def test_invalid_pe_causes_failure_even_with_all_files_present(self):
        with patch.object(module.compiled, "verify", return_value=["invalid ARM64EC PE"]):
            issues, receipt = module.verify(self.root, "d" * 40)
        self.assertIn("invalid ARM64EC PE", issues)
        self.assertFalse(receipt["validated"])


if __name__ == "__main__":
    unittest.main()
