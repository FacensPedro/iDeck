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
        paths = [
            ROOT / "scripts/build_ipa.sh",
            ROOT / "scripts/build_native_runtime.sh",
            ROOT / ".github/workflows/ios.yml",
        ]
        for path in paths:
            content = path.read_text(encoding="utf-8")
            with self.subTest(path=path):
                for name in ("KIT_FLAGS", "KIT_ARGS", "OPTIONS", "WOW64_FLAGS"):
                    self.assertNotIn('"${' + name + '[@]}"', content)

    def test_native_bundle_is_verified_with_and_without_wow64(self):
        source = (ROOT / "scripts/build_ipa.sh").read_text(encoding="utf-8")
        self.assertIn(
            'python3 scripts/verify_madeira_bundle.py --app "$APP" --require --require-wow64',
            source,
        )
        self.assertIn(
            'python3 scripts/verify_madeira_bundle.py --app "$APP" --require\n',
            source,
        )


if __name__ == "__main__":
    unittest.main()
