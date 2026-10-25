import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ensure_metal_toolchain.sh"


class MetalToolchainTests(unittest.TestCase):
    def check_case(self, ready=False, download_fails=False, stays_missing=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tools = root / "bin"
            tools.mkdir()
            state = root / "state"
            state.mkdir()
            (tools / "uname").write_text("#!/bin/bash\necho Darwin\n")
            (tools / "xcrun").write_text(
                '#!/bin/bash\n'
                'if [[ "$1" == "--kill-cache" ]]; then exit 0; fi\n'
                'out=""\n'
                'while [[ $# -gt 0 ]]; do\n'
                '  if [[ "$1" == "-o" ]]; then shift; out="$1"; break; fi\n'
                '  shift\n'
                'done\n'
                'if [[ -f "$FAKE_STATE/ready" && ! -f "$FAKE_STATE/broken" ]]; then\n'
                '  printf AIR > "$out"\n'
                '  exit 0\n'
                'fi\n'
                'echo "metal toolchain missing" >&2\n'
                'exit 1\n'
            )
            (tools / "xcodebuild").write_text(
                '#!/bin/bash\n'
                'printf "%s\\n" "$*" >> "$FAKE_STATE/downloads"\n'
                'if [[ -f "$FAKE_STATE/fail_download" ]]; then exit 10; fi\n'
                'touch "$FAKE_STATE/ready"\n'
            )
            for file in tools.iterdir():
                file.chmod(0o755)
            if ready:
                (state / "ready").touch()
            if download_fails:
                (state / "fail_download").touch()
            if stays_missing:
                (state / "broken").touch()
            env = os.environ.copy()
            env["PATH"] = str(tools) + os.pathsep + env["PATH"]
            env["FAKE_STATE"] = str(state)
            result = subprocess.run(["bash", str(SCRIPT)], env=env, text=True, capture_output=True, check=False)
            download_file = state / "downloads"
            calls = download_file.read_text().splitlines() if download_file.exists() else []
            return result, calls

    def test_ready_toolchain_skips_download(self):
        result, calls = self.check_case(ready=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_missing_toolchain_is_installed(self):
        result, calls = self.check_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["-downloadComponent metalToolchain"])

    def test_failed_download_stops_build(self):
        result, calls = self.check_case(download_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["-downloadComponent metalToolchain"])

    def test_nonworking_installation_stops_build(self):
        result, calls = self.check_case(stays_missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not produce a working", result.stderr)
        self.assertEqual(calls, ["-downloadComponent metalToolchain"])


if __name__ == "__main__":
    unittest.main()
