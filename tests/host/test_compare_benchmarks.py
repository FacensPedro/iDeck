import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from support import ROOT


class CompareBenchmarksTests(unittest.TestCase):
    def test_flags_regressions_per_game_against_oldest_version(self):
        with tempfile.TemporaryDirectory() as d:
            for v, b, ram, fps in (("1.5.0", "39", 2000, 30.0), ("1.6.0", "41", 2400, 30.0)):
                (Path(d) / f"game-{v}.json").write_text(json.dumps({
                    "outcome": "closed",
                    "environment": {"appVersion": v, "appBuild": b},
                    "metrics": {"kind": "game", "label": "G", "memoryPeakMB": ram, "fpsAverage": fps},
                }))
            out = subprocess.run([sys.executable, str(ROOT / "scripts/compare_benchmarks.py"), "--dir", d],
                                 check=True, text=True, capture_output=True).stdout
        self.assertIn("1.5.0(39)", out)
        self.assertIn("2400.0 (+20%!)", out)
        self.assertIn("30.0 (+0%)", out)


if __name__ == "__main__":
    unittest.main()
