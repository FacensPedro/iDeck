import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "fex_stage3", ROOT / "scripts/verify_madeira_fex_stage3.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MadeiraFEXStage3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        caches = {
            module.IOS_CACHE: (
                "TUNE_CPU:STRING=none\n"
                "CMAKE_OSX_ARCHITECTURES:STRING=arm64\n"
            ),
            module.ARM64EC_CACHE: (
                "FEX_IOS_HOST_BUILD:BOOL=ON\n"
                "MINGW_TRIPLE:STRING=arm64ec-w64-mingw32\n"
                "ENABLE_LTO:BOOL=OFF\n"
                "CMAKE_C_FLAGS:STRING=-DFEX_IOS_HOST=1\n"
                "CMAKE_CXX_FLAGS:STRING=-DFEX_IOS_HOST=1\n"
                "CMAKE_ASM_FLAGS:STRING=-DFEX_IOS_HOST=1\n"
            ),
        }
        for name, source in caches.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        for name in module.ARTIFACTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"MZ" + bytes(4096))

    def test_exact_config_and_compiled_fex_are_accepted_with_receipt(self):
        with patch.object(module.compiled, "verify", return_value=[]):
            errors, receipt = module.verify(self.root, "f" * 40)
        self.assertEqual(errors, [])
        self.assertEqual(receipt["stage"], 3)
        self.assertEqual(receipt["profile"], "d3d11-x86_64-only")
        self.assertTrue(receipt["validated"])
        self.assertEqual(len(receipt["artifact_hashes"]), len(module.ARTIFACTS))
        self.assertIn("iPad JIT memory allocation", receipt["not_validated"])

    def test_arm64ec_assembly_must_define_ios_transition(self):
        path = self.root / module.ARM64EC_CACHE
        text = path.read_text().replace(
            "CMAKE_ASM_FLAGS:STRING=-DFEX_IOS_HOST=1",
            "CMAKE_ASM_FLAGS:STRING=",
        )
        path.write_text(text)
        with patch.object(module.compiled, "verify", return_value=[]):
            errors, receipt = module.verify(self.root, "a" * 40)
        self.assertTrue(any("CMAKE_ASM_FLAGS" in message for message in errors))
        self.assertFalse(receipt["validated"])

    def test_fex_cpu_tuning_must_not_claim_native_macos_cpu(self):
        path = self.root / module.IOS_CACHE
        path.write_text(path.read_text().replace("TUNE_CPU:STRING=none", "TUNE_CPU:STRING=native"))
        with patch.object(module.compiled, "verify", return_value=[]):
            errors, _ = module.verify(self.root, "b" * 40)
        self.assertTrue(any("TUNE_CPU" in message for message in errors))

    def test_missing_and_small_artifact_fail_closed(self):
        path = self.root / module.FEX_PE[0] if hasattr(module, "FEX_PE") else self.root / module.ARTIFACTS[-1]
        path.write_bytes(b"MZ")
        with patch.object(module.compiled, "verify", return_value=[]):
            errors, receipt = module.verify(self.root, "c" * 40)
        self.assertTrue(any("manifest is incomplete" in message for message in errors))
        self.assertFalse(receipt["validated"])

    def test_missing_cmake_configuration_is_rejected(self):
        (self.root / module.IOS_CACHE).unlink()
        with patch.object(module.compiled, "verify", return_value=[]):
            errors, _ = module.verify(self.root, "d" * 40)
        self.assertTrue(any("configuration missing" in message for message in errors))

    def test_wrong_mingw_target_and_lto_are_rejected(self):
        path = self.root / module.ARM64EC_CACHE
        path.write_text(path.read_text().replace("arm64ec-w64-mingw32", "aarch64-w64-mingw32")
                        .replace("ENABLE_LTO:BOOL=OFF", "ENABLE_LTO:BOOL=ON"))
        with patch.object(module.compiled, "verify", return_value=[]):
            errors, _ = module.verify(self.root, "e" * 40)
        self.assertTrue(any("MINGW_TRIPLE" in message for message in errors))
        self.assertTrue(any("ENABLE_LTO" in message for message in errors))


if __name__ == "__main__":
    unittest.main()
