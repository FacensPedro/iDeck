import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("madeira_dxmt_stage5", ROOT / "scripts/verify_madeira_dxmt_stage5.py")
stage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage)


class MadeiraDXMTStage5Tests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for relative in stage.DXMT_ARTIFACTS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"linked DXMT native output" * 256)
        for relative in stage.REQUIRED_BUILDS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# real meson build file\n" * 8, encoding="utf-8")
        for name in stage.SHADERS:
            for relative in (
                f"dxmt/src/airconv/shaders/{name}.metal",
                f"build/dxmt-ios/shader-headers/{name}.air",
                f"build/dxmt-ios/shader-headers/{name}.h",
            ):
                path = self.root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"generated Metal intermediate" * 5)

    def verify_with_architectures(self):
        with patch.object(stage.compiled, "verify", return_value=[]):
            with patch.object(stage.compiled, "verify_archive", return_value=None):
                with patch.object(stage.compiled.bundle, "_pe_arch_error", return_value=None):
                    return stage.verify(self.root, stage.SOURCE_REVISION)

    def test_valid_outputs_have_nine_sha256_hashes_without_claiming_device_execution(self):
        errors, receipt = self.verify_with_architectures()
        self.assertEqual(errors, [])
        self.assertTrue(receipt["validated"])
        self.assertEqual(receipt["stage"], 5)
        self.assertEqual(receipt["backend"], "dxmt-d3d11-metal")
        self.assertEqual(len(receipt["artifact_hashes"]), 9)
        self.assertIn("Metal on-device frame presentation", receipt["not_validated"])

    def test_missing_arm64ec_d3d11_frontend_fails_closed(self):
        (self.root / "app/Madeira/arm64ec-windows/d3d11.dll").unlink()
        errors, receipt = self.verify_with_architectures()
        self.assertFalse(receipt["validated"])
        self.assertTrue(any("d3d11.dll" in error for error in errors))

    def test_missing_native_aarch64_frontend_fails_closed(self):
        (self.root / "app/Madeira/aarch64-windows/dxgi.dll").unlink()
        errors, receipt = self.verify_with_architectures()
        self.assertFalse(receipt["validated"])
        self.assertTrue(any("aarch64" in error for error in errors))

    def test_metal_shader_preflight_and_header_outputs_are_required(self):
        (self.root / "build/dxmt-ios/shader-headers/air_tessellation.h").unlink()
        errors, receipt = self.verify_with_architectures()
        self.assertTrue(any("air_tessellation.h" in error for error in errors))
        self.assertFalse(receipt["validated"])

    def test_meson_source_build_files_are_required(self):
        (self.root / "dxmt/build-arm64ec/build.ninja").unlink()
        errors, receipt = self.verify_with_architectures()
        self.assertTrue(any("source-build configuration absent" in error for error in errors))
        self.assertFalse(receipt["validated"])

    def test_wrong_architecture_of_aarch64_pe_is_rejected(self):
        with patch.object(stage.compiled, "verify", return_value=[]):
            with patch.object(stage.compiled, "verify_archive", return_value=None):
                with patch.object(stage.compiled.bundle, "_pe_arch_error", side_effect=lambda path, require_arm64ec: "bad native PE" if not require_arm64ec else None):
                    errors, receipt = stage.verify(self.root, stage.SOURCE_REVISION)
        self.assertTrue(any("bad native PE" in error for error in errors))
        self.assertFalse(receipt["validated"])

    def test_wrong_architecture_of_arm64ec_pe_is_rejected(self):
        with patch.object(stage.compiled, "verify", return_value=[]):
            with patch.object(stage.compiled, "verify_archive", return_value=None):
                with patch.object(stage.compiled.bundle, "_pe_arch_error", side_effect=lambda path, require_arm64ec: "bad ARM64EC metadata" if require_arm64ec else None):
                    errors, receipt = stage.verify(self.root, stage.SOURCE_REVISION)
        self.assertTrue(any("bad ARM64EC metadata" in error for error in errors))
        self.assertFalse(receipt["validated"])

    def test_no_proprietary_converter_or_d3d12_in_artifacts(self):
        self.assertEqual(len(stage.DXMT_ARTIFACTS), 9)
        for artifact in stage.DXMT_ARTIFACTS:
            self.assertNotIn("d3d12", artifact.lower())
            self.assertNotIn("metalirconverter", artifact.lower())

    def test_standalone_script_builds_before_wow64_and_d3d12(self):
        source = (ROOT / "scripts/build_madeira_components.sh").read_text(encoding="utf-8")
        self.assertIn('IDECK_MADEIRA_STOP_AFTER:-all', source)
        self.assertIn('STOP_AFTER" == "dxmt"', source)
        self.assertIn('verify_madeira_dxmt_stage5.py', source)
        self.assertLess(source.index('if [[ "$STOP_AFTER" == "dxmt" ]]; then', source.index('DXMT_EC_MODULES=(')),
                        source.index('bash "$MD/build/fex-wow64/build.sh"'))
        self.assertLess(source.index('python3 "$ROOT/scripts/verify_madeira_dxmt_stage5.py"'),
                        source.index('bash "$MD/build/madeira-d3d12/build-pe.sh"'))


if __name__ == "__main__":
    unittest.main()
