import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
FILE = ROOT / "scripts/verify_madeira_component_outputs.py"
SPEC = importlib.util.spec_from_file_location("madeira_outputs", FILE)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class MadeiraOutputArchitectureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in checker.FEX_ARCHIVES + checker.WINE_ARCHIVES + checker.DXMT_ARCHIVES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"archive" * 2048)
        for name in checker.FEX_PE + checker.WINE_PE + checker.DXMT_PE:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"MZ" + bytes(4096))

    def test_all_compilation_stages_reject_missing_real_files(self):
        for stage, missing_file in (
            ("fex", checker.FEX_ARCHIVES[0]),
            ("wine", checker.WINE_PE[0]),
            ("dxmt", checker.DXMT_ARCHIVES[0]),
        ):
            with self.subTest(stage=stage):
                path = self.root / missing_file
                contents = path.read_bytes()
                path.unlink()
                self.assertTrue(checker.verify(self.root, stage))
                path.write_bytes(contents)

    def test_macho_archive_requires_arm64(self):
        path = self.root / checker.FEX_ARCHIVES[0]
        wrong = subprocess.CompletedProcess([], 0, "x86_64\n", "")
        with patch.object(checker.subprocess, "run", return_value=wrong):
            self.assertIn("unexpected architecture", checker.verify_archive(path))

    def test_arm64ec_pe_parser_is_mandatory(self):
        path = self.root / checker.FEX_PE[0]
        with patch.object(checker.bundle, "_pe_arch_error", return_value="not ARM64EC") as method:
            self.assertEqual(checker.verify_pe(path), "not ARM64EC")
            method.assert_called_once_with(path, require_arm64ec=True)

    def test_all_fex_wine_dxmt_stages_require_genuine_architecture_results(self):
        valid = subprocess.CompletedProcess([], 0, "arm64\n", "")
        with patch.object(checker.subprocess, "run", return_value=valid):
            with patch.object(checker.bundle, "_pe_arch_error", return_value=None):
                for stage in ("fex", "wine", "dxmt"):
                    with self.subTest(stage=stage):
                        self.assertEqual(checker.verify(self.root, stage), [])

    def test_compiler_or_pe_errors_fail_closed(self):
        valid = subprocess.CompletedProcess([], 0, "arm64\n", "")
        with patch.object(checker.subprocess, "run", return_value=valid):
            with patch.object(checker.bundle, "_pe_arch_error", return_value="bad PE"):
                self.assertTrue(any("bad PE" in error for error in checker.verify(self.root, "dxmt")))

    def test_unknown_stage_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "invalid Madeira compilation stage"):
            checker.verify(self.root, "fake")


if __name__ == "__main__":
    unittest.main()
