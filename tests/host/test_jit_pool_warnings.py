"""JIT pool warnings from the BioShock 2 log (2026-11-22).

- A widened executable window turns the split pool on, so the pool continues past
  the main thread's stack instead of shrinking to 496MB.
- iOS's refusal of the no-footprint exemption is only a warning when memory is short.
"""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
JIT = (ROOT / "iDeck" / "MadeiraJIT" / "StikJITHelper.swift").read_text()


class SplitPoolForWidenedWindowTests(unittest.TestCase):
    def test_widened_window_turns_split_on(self):
        self.assertIn('let splitValue = splitSetting.isEmpty && exeWinWantedMB > 128 ? "1" : splitSetting', JIT)

    def test_explicit_setting_wins(self):
        self.assertIn('(MadeiraConfig.gameValue("pool-split") ?? MadeiraConfig.get("pool-split") ?? "")', JIT)
        self.assertIn("pool-split = 0 turns this off", JIT)

    def test_window_size_known_before_split(self):
        self.assertLess(JIT.index("let exeWinWantedMB: Int = {"), JIT.index("let splitValue = splitSetting"))
        self.assertLess(JIT.index("let splitValue = splitSetting"), JIT.index("let pairOff ="))


class NoFootprintWarningTests(unittest.TestCase):
    def body(self) -> str:
        start = JIT.index("static func reportNoFootprint")
        return JIT[start:JIT.index("static func allocatePool", start)]

    def test_warns_only_when_memory_is_short(self):
        body = self.body()
        self.assertIn("os_proc_available_memory()", body)
        self.assertIn("if availableMB < footprintWarningMB {", body)
        self.assertIn("static let footprintWarningMB = 2048", JIT)
        warning = body.index("⚠️")
        self.assertGreater(warning, body.index("if availableMB < footprintWarningMB {"))
        self.assertLess(warning, body.index("} else {", body.index("if availableMB < footprintWarningMB {")))

    def test_refusal_is_still_recorded(self):
        body = self.body()
        self.assertIn("poolCountsAgainstFootprint = !applied", body)
        self.assertIn("[no-footprint] pool applied=false available=", body)

    def test_darwin_imported(self):
        self.assertIn("import Darwin", JIT)


if __name__ == "__main__":
    unittest.main()
