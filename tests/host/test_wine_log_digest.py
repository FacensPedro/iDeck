"""The Wine log is small enough to read (2.13.1).

- MADEIRA_DEBUG_VERBOSE no longer makes Madeira replace WINEDEBUG with
  trace+syscall/trace+file (16 MB, 220,000 lines for one session).
- Copied and shared Wine logs are a digest: last session, no call traces,
  lines capped, at most 256 KB.
"""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CLIP = (ROOT / "iDeck" / "WineLogClipboard.swift").read_text()
ENV = (ROOT / "iDeck" / "WindowsEnvironment.swift").read_text()
PATCH = (ROOT / "patches" / "madeira-wine-idle-logging.patch").read_text()


class WineDebugTests(unittest.TestCase):
    def test_verbose_off_so_our_channels_apply(self):
        self.assertIn('setenv("MADEIRA_DEBUG_VERBOSE", "0", 1)', ENV)
        # The patched non-verbose branch keeps a WINEDEBUG that is already set.
        self.assertIn('if (!configured_debug || !*configured_debug)', PATCH)

    def test_channels_keep_what_bug_reports_read(self):
        start = ENV.index('static let wineDebugChannels = "')
        channels = ENV[start:ENV.index("\n", start)]
        for kept in ("err+all", "trace+process", "trace+loaddll"):
            self.assertIn(kept, channels)
        for dropped in ("trace+syscall", "trace+file", "trace+module", "fixme+all"):
            self.assertNotIn(dropped, channels)


class DigestTests(unittest.TestCase):
    def body(self) -> str:
        start = CLIP.index("enum WineLogDigest {")
        return CLIP[start:CLIP.index("/// Makes iDeck's logs", start)]

    def test_limits(self):
        body = self.body()
        self.assertIn("static let maximumLineBytes = 400", body)
        self.assertIn("static let maximumBytes = 256 << 10", body)
        self.assertIn('Data("[wineserver-bridge] ws_log test".utf8)', body)

    def test_call_traces_left_out_and_process_traces_kept(self):
        body = self.body()
        self.assertIn('static let callTraces = [":SysCall ", ":SysRet ", ":Call ", ":Ret "]', body)
        self.assertIn('static let keptTraces = [":trace:process:", ":trace:loaddll:"]', body)

    def test_utf8_safe_cut_and_compaction(self):
        body = self.body()
        self.assertIn("line[end] & 0xC0 == 0x80", body)
        self.assertIn("LogCompactor.compactedData(Data(kept))", body)

    def test_copy_and_share_use_it(self):
        self.assertIn("PrivacyRedactor.redact(WineLogDigest.shared(raw, from: source))", CLIP)
        self.assertIn("try redact(WineLogDigest.shared(try Data(contentsOf: source), from: source))", CLIP)
        self.assertIn('url.lastPathComponent.hasPrefix("madeira-log")', CLIP)


if __name__ == "__main__":
    unittest.main()
