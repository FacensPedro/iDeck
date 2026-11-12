"""patches/series.txt and scripts/apply_madeira_patches.py."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FETCH = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
# Detected by their content in the fetch script instead of a reverse check.
CONTENT_DETECTED = {"madeira-ntdll-pe-only.patch", "madeira-wineserver-from-source.patch",
                    "dxmt-metal27-tessellation-atomic.patch", "ideck-vcruntime-wow64.patch"}


def module():
    spec = importlib.util.spec_from_file_location("patches", ROOT / "scripts/apply_madeira_patches.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class SeriesTests(unittest.TestCase):
    def test_every_patch_is_listed_once_or_content_detected(self):
        listed = [name for _, _, name in module().series()]
        self.assertEqual(len(listed), len(set(listed)))
        on_disk = {p.name for p in (ROOT / "patches").glob("*.patch")}
        self.assertEqual(set(listed) | CONTENT_DETECTED, on_disk)
        for name in CONTENT_DETECTED:
            self.assertIn(f'"$ROOT/patches/{name}"', FETCH)

    def test_every_group_runs_from_the_fetch_in_order(self):
        groups = []
        for group, _, _ in module().series():
            if group not in groups:
                groups.append(group)
        positions = [FETCH.index(f'apply_madeira_patches.py" "$DEST" {g}\n') for g in groups]
        self.assertEqual(positions, sorted(positions))

    def test_compat_backports_come_before_the_vcruntime_overlay(self):
        self.assertLess(FETCH.index('"$DEST" backports'), FETCH.index('VCRT_PATCH="$ROOT/patches/ideck-vcruntime-wow64.patch"'))

    def test_post_checks_are_kept(self):
        for check in ("iDeckARMHostFeatures.h", "Features.CPUMIDRs.resize(8, 0x611F0250)", "brk #0x5a5a",
                      "int wine_process_thread_finished(void)"):
            self.assertIn(check, FETCH)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.repo = self.root / "madeira"
        (self.repo / "src").mkdir(parents=True)
        (self.repo / "src/a.c").write_text("one\ntwo\n")
        (self.repo / "src/b.c").write_text("three\n")
        subprocess.run(["git", "-C", str(self.repo), "init", "-q"], check=True)
        self.patches = self.root / "patches"
        self.patches.mkdir()
        (self.patches / "first.patch").write_text("--- a/src/a.c\n+++ b/src/a.c\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n")
        (self.patches / "second.patch").write_text("--- a/src/b.c\n+++ b/src/b.c\n@@ -1 +1 @@\n-three\n+THREE\n")
        self.series = self.patches / "series.txt"
        self.series.write_text("# comment\ngroup . first.patch\ngroup . second.patch\nother . first.patch\n")

    def tearDown(self):
        self.folder.cleanup()

    def run_group(self, group):
        return module().apply_group(self.repo, group, path=self.series, patches=self.patches)

    def test_applies_in_order_then_skips(self):
        self.assertEqual(self.run_group("group"), 0)
        self.assertEqual((self.repo / "src/a.c").read_text(), "one\nTWO\n")
        self.assertEqual((self.repo / "src/b.c").read_text(), "THREE\n")
        self.assertEqual(self.run_group("group"), 0)  # already applied: skipped, not doubled
        self.assertEqual((self.repo / "src/a.c").read_text(), "one\nTWO\n")

    def test_overlapping_patches_run_twice(self):
        # third.patch rewrites the line first.patch made, so first.patch no longer
        # reverses; the stamp keeps the second run from stopping.
        (self.patches / "third.patch").write_text("--- a/src/a.c\n+++ b/src/a.c\n@@ -1,2 +1,2 @@\n one\n-TWO\n+2\n")
        self.series.write_text("group . first.patch\ngroup . third.patch\n")
        self.assertEqual(self.run_group("group"), 0)
        self.assertEqual(self.run_group("group"), 0)
        self.assertEqual((self.repo / "src/a.c").read_text(), "one\n2\n")

    def test_drifted_sources_and_unknown_groups_stop(self):
        (self.repo / "src/a.c").write_text("changed\n")
        self.assertEqual(self.run_group("group"), 2)
        self.assertEqual(self.run_group("missing"), 2)

    def test_a_malformed_line_is_an_error(self):
        self.series.write_text("group first.patch\n")
        with self.assertRaises(ValueError):
            self.run_group("group")


if __name__ == "__main__":
    unittest.main()
