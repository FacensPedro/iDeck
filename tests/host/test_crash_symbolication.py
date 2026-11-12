"""MetricKit crash stacks are named on the device before they reach the bug report."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CRASH = (ROOT / "iDeck/IOSCrashDiagnostics.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()


class CrashSymbolicationTests(unittest.TestCase):
    def test_frames_are_resolved_through_loaded_images_by_uuid(self):
        self.assertIn("import MachO", CRASH)
        self.assertIn("_dyld_get_image_header(index)", CRASH)
        self.assertIn("load.cmd == UInt32(LC_UUID)", CRASH)
        self.assertIn("images[uuid.uppercased()]", CRASH)
        self.assertIn("dladdr(address, &info)", CRASH)

    def test_the_crashed_thread_is_logged_first_and_in_full(self):
        self.assertIn('let shown = attributed ? list : Array(list.prefix(otherFrames))', CRASH)
        self.assertIn('"(crashed)"', CRASH)
        self.assertIn('AppLog.record("[ios-crash] " + line)', CRASH)
        # "crash" is an error keyword, so the crashed-thread line is kept in the report.
        self.assertIn('"crash"', REPORT[REPORT.index("private static let errors"):])


if __name__ == "__main__":
    unittest.main()
