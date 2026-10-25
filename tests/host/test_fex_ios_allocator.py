import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "build_fex_ios_allocator.sh"


class FEXIOSAllocatorTests(unittest.TestCase):
    def run_case(self, cache=True, missing=False, fail_build=False, bad_arch=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            madeira = root / "Madeira"
            build = madeira / "FEX" / "build-ios"
            build.mkdir(parents=True)
            if cache:
                (build / "CMakeCache.txt").write_text("CMAKE_SYSTEM_NAME:STRING=iOS\n")
            tools = root / "bin"
            tools.mkdir()
            state = root / "state"
            state.mkdir()
            for flag, enabled in (
                ("skip_archive", missing),
                ("fail_build", fail_build),
                ("bad_arch", bad_arch),
            ):
                if enabled:
                    (state / flag).touch()
            cmake = tools / "cmake"
            cmake.write_text(
                "#!/bin/bash\n"
                'echo "$*" >> "$FAKE_STATE/commands"\n'
                'if [[ -f "$FAKE_STATE/fail_build" ]]; then exit 7; fi\n'
                'if [[ ! -f "$FAKE_STATE/skip_archive" ]]; then\n'
                '  mkdir -p "$FAKE_MADEIRA/FEX/build-ios/FEXCore/Source"\n'
                '  printf archive > "$FAKE_MADEIRA/FEX/build-ios/FEXCore/Source/libJemallocLibs.a"\n'
                'fi\n'
            )
            xcrun = tools / "xcrun"
            xcrun.write_text(
                "#!/bin/bash\n"
                '[[ "$1" == "lipo" && "$2" == "-archs" ]] || exit 5\n'
                'if [[ -f "$FAKE_STATE/bad_arch" ]]; then echo arm64ec; else echo arm64; fi\n'
            )
            cmake.chmod(0o755)
            xcrun.chmod(0o755)
            env = os.environ.copy()
            env.update({
                "PATH": str(tools) + os.pathsep + env["PATH"],
                "IDECK_MADEIRA_ROOT": str(madeira),
                "FAKE_MADEIRA": str(madeira),
                "FAKE_STATE": str(state),
            })
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                env=env, text=True, capture_output=True, check=False,
            )
            commands_file = state / "commands"
            commands = commands_file.read_text().splitlines() if commands_file.exists() else []
            return result, commands

    def test_compiles_arm64_allocator_archive(self):
        result, commands = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(commands), 1)
        self.assertIn("--target JemallocLibs", commands[0])
        self.assertIn("build-ios", commands[0])

    def test_rejects_missing_configuration(self):
        result, commands = self.run_case(cache=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("configuration is missing", result.stderr)
        self.assertEqual(commands, [])

    def test_rejects_missing_archive(self):
        result, commands = self.run_case(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("was not created", result.stderr)
        self.assertEqual(len(commands), 1)

    def test_rejects_windows_arm64ec_archive(self):
        result, commands = self.run_case(bad_arch=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not contain arm64", result.stderr)
        self.assertEqual(len(commands), 1)

    def test_surfaces_failed_cmake_build(self):
        result, commands = self.run_case(fail_build=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(commands), 1)


if __name__ == "__main__":
    unittest.main()
