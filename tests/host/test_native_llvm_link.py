import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LINK_SCRIPT = ROOT / "scripts" / "link_madeira_native.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "ios.yml"


class NativeLLVMLinkerTests(unittest.TestCase):
    def test_required_libraries_are_after_static_archives(self):
        source = LINK_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("FLAGS+=(-lcurses -lxml2)", source)
        last_archive = source.index('FLAGS+=("${ARCHIVES[$index]}")')
        system_libs = source.index("FLAGS+=(-lcurses -lxml2)")
        output = source.index('> "$OUT/link-flags.txt"')
        self.assertLess(last_archive, system_libs)
        self.assertLess(system_libs, output)

    def test_iphoneos_probe_requires_both_missing_symbols(self):
        source = (ROOT / "tests" / "host" / "NativeIOSLinkDependencies.c").read_text(encoding="utf-8")
        for symbol in ("setupterm", "xmlReadMemory"):
            with self.subTest(symbol=symbol):
                self.assertRegex(source, rf"\b{symbol}\b")
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("NativeIOSLinkDependencies.c", workflow)
        self.assertRegex(workflow, r"-lcurses\s+-lxml2")
        self.assertIn("-arch arm64", workflow)


if __name__ == "__main__":
    unittest.main()
