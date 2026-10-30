import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/verify_madeira_toolchains.sh"
NATIVE = ROOT / "scripts/build_native_runtime.sh"
SDK = ROOT / "scripts/llvm_ios_sdk.py"


class MadeiraToolchainGateTests(unittest.TestCase):
    def test_scripts_are_valid_bash(self):
        for path in (CHECKER, NATIVE):
            with self.subTest(path=path.name):
                subprocess.run(["bash", "-n", str(path)], check=True)

    def test_sdk_cache_must_have_exact_revision_and_generated_headers(self):
        source = CHECKER.read_text()
        self.assertIn("llvmorg-15.0.7", source)
        self.assertIn('python3 "$ROOT/scripts/llvm_ios_sdk.py" check', source)
        self.assertIn('bash "$ROOT/scripts/verify_dxmt_llvm.sh"', source)
        sdk_source = SDK.read_text()
        self.assertIn("ideck-sdk.json", sdk_source)
        self.assertIn("IntrinsicEnums.inc", sdk_source)
        self.assertIn("IntrinsicImpl.inc", sdk_source)

    def test_arm64ec_coff_output_is_verified_not_stubbed(self):
        source = CHECKER.read_text()
        self.assertIn('arm64ec-w64-mingw32-clang', source)
        self.assertIn('"$MINGW" -x c -c', source)
        self.assertIn('0xA641', source)
        self.assertIn('struct.unpack_from("<H", data, 0)', source)
        self.assertIn('raise SystemExit', source)

    def test_all_required_ios_archives_are_verified(self):
        source = CHECKER.read_text()
        self.assertIn('xcrun lipo -archs', source)
        self.assertIn('[[ "$arches" == "arm64" ]]', source)
        for lib in ("LLVMCore", "LLVMSupport", "LLVMBitReader", "LLVMBitWriter",
                    "gnutls", "gmp", "nettle", "hogweed", "avformat",
                    "avcodec", "swresample", "avutil", "libfreetype.a"):
            with self.subTest(library=lib):
                self.assertIn(lib, source)

    def test_d3d11_native_builder_never_reuses_old_d3d12_kits(self):
        source = NATIVE.read_text()
        self.assertIn('export IDECK_MADEIRA_GRAPHICS="${IDECK_MADEIRA_GRAPHICS:-d3d11}"', source)
        self.assertIn('export IDECK_PREBUILT_MODE="${IDECK_PREBUILT_MODE:-prefer}"', source)
        self.assertIn('KIT_ARGS=(--graphics "$IDECK_MADEIRA_GRAPHICS")', source)
        self.assertIn('export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-1}"', source)
        self.assertIn('D3D12 requires confirmed rights', source)

    def test_architecture_gate_refuses_to_run_without_macos(self):
        result = subprocess.run(
            ["bash", str(CHECKER)],
            capture_output=True, text=True, check=False
        )
        if subprocess.run(["uname", "-s"], capture_output=True, text=True, check=True).stdout.strip() != "Darwin":
            self.assertEqual(result.returncode, 2)
            self.assertIn("macOS/Xcode required", result.stderr)


if __name__ == "__main__":
    unittest.main()
