import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ensure_madeira_bison.sh"
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text()
NATIVE = (ROOT / "scripts/build_madeira_components.sh").read_text()


class WineBisonPreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.executables = self.root / "bin"
        self.executables.mkdir()
        self.brew_prefix = self.root / "homebrew-bison"
        self.brew_log = self.root / "brew-calls.txt"
        self.github_path = self.root / "GITHUB_PATH"
        self.github_path.touch()
        self.environment = dict(os.environ)
        self.environment.update({
            "PATH": str(self.executables) + os.pathsep + os.environ.get("PATH", ""),
            "FAKE_BREW_PREFIX": str(self.brew_prefix),
            "FAKE_BREW_LOG": str(self.brew_log),
            "GITHUB_PATH": str(self.github_path),
        })

    def executable(self, path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/bash\n" + contents, encoding="utf-8")
        path.chmod(0o755)

    def make_brew(self, new_version="3.8.2"):
        self.environment["FAKE_NEW_BISON_VERSION"] = new_version
        self.executable(self.executables / "brew", """
printf '%s\\n' "$*" >> "$FAKE_BREW_LOG"
if [[ "$1" == "--prefix" && "$2" == "bison" ]]; then
  printf '%s\\n' "$FAKE_BREW_PREFIX"
elif [[ "$1" == "install" && "$2" == "bison" ]]; then
  mkdir -p "$FAKE_BREW_PREFIX/bin"
  printf '#!/bin/bash\\necho "bison (GNU Bison) %s"\\n' "$FAKE_NEW_BISON_VERSION" > "$FAKE_BREW_PREFIX/bin/bison"
  chmod +x "$FAKE_BREW_PREFIX/bin/bison"
else
  exit 2
fi
""")

    def invoke(self):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; bison --version', "bash", str(SCRIPT)],
            env=self.environment, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False,
        )

    def test_old_system_bison_is_replaced_with_homebrew_bison(self):
        self.executable(self.executables / "bison", 'echo "bison (GNU Bison) 2.3"\n')
        self.make_brew("3.8.2")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3.8.2", result.stdout)
        self.assertIn("install bison", self.brew_log.read_text())
        self.assertIn(str(self.brew_prefix / "bin"), self.github_path.read_text())

    def test_existing_compatible_bison_does_not_trigger_homebrew(self):
        self.executable(self.executables / "bison", 'echo "bison (GNU Bison) 3.0.0"\n')
        self.make_brew()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3.0.0", result.stdout)
        self.assertFalse(self.brew_log.exists())
        self.assertEqual(self.github_path.read_text(), "")

    def test_bad_homebrew_bison_fails_closed(self):
        self.executable(self.executables / "bison", 'echo "bison (GNU Bison) 2.3"\n')
        self.make_brew("2.9.9")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("older than 3.0", result.stderr)

    def test_github_workflow_checks_version_before_expensive_build(self):
        self.assertIn("bash scripts/ensure_madeira_bison.sh", WORKFLOW)
        self.assertIn("Verify Wine parser prerequisites before compiling LLVM", WORKFLOW)
        self.assertNotIn("meson:meson bison:bison", WORKFLOW)
        self.assertLess(
            WORKFLOW.index("Verify Wine parser prerequisites before compiling LLVM"),
            WORKFLOW.index("Prepare ARM64EC and iOS LLVM toolchains"),
        )
        self.assertIn('source "$ROOT/scripts/ensure_madeira_bison.sh"', NATIVE)


if __name__ == "__main__":
    unittest.main()
