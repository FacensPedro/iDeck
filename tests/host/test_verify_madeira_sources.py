import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_madeira_sources", ROOT / "scripts/verify_madeira_sources.py"
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MadeiraPublicSourceTests(unittest.TestCase):
    def test_valid_recursive_submodule_status(self):
        lines = (
            " " + "a" * 40 + " FEX (heads/ios-port-2607)",
            " " + "b" * 40 + " FEX/External/rpmalloc (heads/ios-madeira)",
            " " + "c" * 40 + " wine (heads/madeira-lgpl)",
            " " + "d" * 40 + " dxmt (heads/ios-port)",
            " " + "e" * 40 + " madeira-dock",
        )
        found = module.check_status("\n".join(lines))
        self.assertEqual(found["FEX"], "a" * 40)
        self.assertEqual(found["FEX/External/rpmalloc"], "b" * 40)

    def test_missing_or_mismatched_gitlinks_are_rejected(self):
        for marker in ("-", "+", "U"):
            with self.subTest(marker=marker):
                with self.assertRaisesRegex(ValueError, "missing, dirty or mismatched"):
                    module.check_status(marker + "a" * 40 + " FEX")
        with self.assertRaises(ValueError):
            module.check_status("")
        with self.assertRaises(ValueError):
            module.check_status(" " + "a" * 40 + " FEX\n " + "a" * 40 + " FEX")

    def test_non_gitlink_tree_entry_is_rejected(self):
        with patch.object(module, "git", return_value="100644 blob " + "a" * 40 + "\tFEX"):
            with self.assertRaisesRegex(ValueError, "missing exact submodule gitlink"):
                module.expected_gitlink(Path("."), "FEX")

    def test_public_fork_url_is_required(self):
        with patch.object(module, "git", return_value="git@github.com:private/fex.git"):
            with self.assertRaisesRegex(ValueError, "unexpected source"):
                module.check_url(Path("."), "FEX", module.PUBLIC_MODULES["FEX"])

    def test_git_preserves_clean_prefix_whitespace(self):
        proc = subprocess.CompletedProcess(
            [], 0, stdout=" " + "a" * 40 + " FEX\n", stderr=""
        )
        with patch.object(module.subprocess, "run", return_value=proc):
            self.assertEqual(module.git(Path("."), "submodule", "status"), proc.stdout.rstrip("\n"))

    def test_requires_fixed_full_commit(self):
        with self.assertRaisesRegex(ValueError, "full 40-character commit"):
            module.verify(Path("."), revision="main")


if __name__ == "__main__":
    unittest.main()
