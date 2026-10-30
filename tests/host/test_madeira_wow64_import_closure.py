import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "madeira_wow64_import_closure",
    ROOT / "scripts/patch_madeira_wow64_import_closure.py",
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class MadeiraWoW64ImportClosureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / "build/wine-i386/build.sh"
        self.script.parent.mkdir(parents=True)
        self.script.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            'present="$(printf \'ucrtbase.dll\\nntdll.dll\\ndinput8.dll\\n\')"\n'
            'for l in ucrtbase.dll ntdll.dll absent.dll; do\n'
            + module.ORIGINAL + '\n'
            '  printf "missing import: %s\\n" "$l"\n'
            'done\n',
            encoding="utf-8",
        )

    def test_patch_is_exact_idempotent_and_preserves_real_missing_imports(self):
        self.assertTrue(module.patch(self.root))
        self.assertFalse(module.patch(self.root))
        completed = subprocess.run(
            ["bash", str(self.script)], capture_output=True, text=True, check=True,
        )
        self.assertEqual(completed.stdout.strip(), "missing import: absent.dll")
        self.assertEqual(completed.stderr, "")

    def test_refuse_unknown_upstream_revision(self):
        original = self.script.read_text().replace(module.ORIGINAL, "exit 99")
        self.script.write_text(original)
        with self.assertRaisesRegex(ValueError, "Unexpected pinned Madeira"):
            module.patch(self.root)
        self.assertEqual(self.script.read_text(), original)

    def test_refuse_ambiguous_duplicate_search(self):
        original = self.script.read_text() + module.ORIGINAL + "\n"
        self.script.write_text(original)
        with self.assertRaisesRegex(ValueError, "Unexpected pinned Madeira"):
            module.patch(self.root)
        self.assertEqual(self.script.read_text(), original)

    def test_large_import_farm_does_not_sigpipe(self):
        present = "\n".join(["first.dll"] + [f"item-{i:05}.dll" for i in range(24000)])
        result = subprocess.run(
            ["bash", "-c",
             'set -euo pipefail; l="first.dll"; present="$(cat)"; '
             'grep -Fxq -- "$l" <<< "$present"; printf "matched\\n"'],
            input=present, capture_output=True, text=True, check=True,
        )
        self.assertEqual(result.stdout, "matched\n")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
