import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FEXCodeBufferNoGuard(unittest.TestCase):
    def test_patch_is_listed_and_skips_guard_on_ios(self):
        series = (ROOT / "patches/series.txt").read_text()
        self.assertIn("native    FEX    fex-ios-code-buffer-no-guard.patch", series)
        patch = (ROOT / "patches/fex-ios-code-buffer-no-guard.patch").read_text()
        self.assertIn("+#ifndef FEX_IOS_HOST", patch)
        self.assertIn("mprotect last page of code buffer", patch)
        self.assertIn("FEXCore/Source/Interface/Core/CPUBackend.cpp", patch)


if __name__ == "__main__":
    unittest.main()
