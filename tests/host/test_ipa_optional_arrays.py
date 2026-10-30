import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class OptionalNativeArgumentsTests(unittest.TestCase):
    def test_empty_and_populated_flags_under_bash_nounset(self):
        script = r"""
set -euo pipefail
FLAGS=()
if [[ "$1" == "1" ]]; then FLAGS+=(--wow64); fi
if [[ "$2" == "1" ]]; then FLAGS+=(--mono); fi
python3 -c 'import json,sys;print(json.dumps(sys.argv[1:]))' ${FLAGS[@]+"${FLAGS[@]}"}
"""
        for wow64 in ("0", "1"):
            for mono in ("0", "1"):
                with self.subTest(wow64=wow64, mono=mono):
                    result = subprocess.run(
                        ["bash", "-c", script, "test-native-options", wow64, mono],
                        capture_output=True, text=True, check=True,
                    )
                    expected = (["--wow64"] if wow64 == "1" else []) + (
                        ["--mono"] if mono == "1" else []
                    )
                    self.assertEqual(json.loads(result.stdout), expected)

    def test_scripts_protect_all_optional_array_expansions(self):
        cases = [
            (ROOT / "scripts/build_ipa.sh", "KIT_FLAGS"),
            (ROOT / "scripts/build_native_runtime.sh", "KIT_ARGS"),
            (ROOT / ".github/workflows/ios.yml", "OPTIONS"),
        ]
        for path, name in cases:
            content = path.read_text(encoding="utf-8")
            with self.subTest(path=path):
                self.assertIn(name + '[@]+"', content)
        build = (ROOT / "scripts/build_ipa.sh").read_text(encoding="utf-8")
        self.assertNotIn("WOW64_FLAGS[@]", build)

    def test_native_d3d11_and_d3d12_default_to_wow64_with_explicit_disable(self):
        ipa = (ROOT / "scripts/build_ipa.sh").read_text(encoding="utf-8")
        native = (ROOT / "scripts/build_native_runtime.sh").read_text(encoding="utf-8")
        components = (ROOT / "scripts/build_madeira_components.sh").read_text(encoding="utf-8")
        self.assertIn('export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-1}"', native)
        self.assertIn('export IDECK_MADEIRA_GRAPHICS="${IDECK_MADEIRA_GRAPHICS:-d3d11}"', native)
        self.assertIn('export IDECK_PREBUILT_MODE="${IDECK_PREBUILT_MODE:-prefer}"', native)
        self.assertIn('D3D12 requires confirmed rights', native)
        self.assertIn('export IDECK_MADEIRA_GRAPHICS="${IDECK_MADEIRA_GRAPHICS:-d3d12}"', ipa)
        self.assertIn('export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-1}"', ipa)
        self.assertIn('IDECK_BUILD_WOW64 must be 0 or 1', ipa)
        self.assertIn('IDECK_BUILD_WOW64 must be 0 or 1', native)
        self.assertIn('export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-0}"', components)
        self.assertIn('bash "$MD/build/fex-wow64/build.sh"', components)
        self.assertIn('bash "$MD/build/wine-i386/build.sh"', components)

    def test_native_bundle_is_verified_with_and_without_wow64(self):
        source = (ROOT / "scripts/build_ipa.sh").read_text(encoding="utf-8")
        self.assertIn(
            'python3 scripts/verify_madeira_bundle.py --app "$APP" --require --require-wow64',
            source,
        )
        self.assertIn(
            'python3 scripts/verify_madeira_bundle.py --app "$APP" --require --graphics "$IDECK_MADEIRA_GRAPHICS"\n',
            source,
        )


if __name__ == "__main__":
    unittest.main()
