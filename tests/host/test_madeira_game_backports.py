import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches/madeira-game-compat-backports.patch"
FETCH = ROOT / "scripts/fetch_madeira_sources.sh"
TARGETS = (
    "app/Madeira/WineProcessBridge.m",
    "build/ntdll-unix/audio_null_ios.c",
    "build/wineserver/mapping_ios.c",
)


def make_pinned_source_fixtures(patch: str, root: Path) -> None:
    current = None
    content = []
    old_line = 1
    in_hunk = False

    def flush() -> None:
        if current is not None:
            path = root / current
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(content) + "\n", encoding="utf-8")

    for line in patch.splitlines():
        if line.startswith("diff --git "):
            flush()
            current = line.split(" b/", 1)[1]
            content = []
            old_line = 1
            in_hunk = False
        elif line.startswith("@@ "):
            match = re.match(r"@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", line)
            if match is None:
                raise ValueError("Unexpected patch hunk header: " + line)
            position = int(match.group(1))
            while old_line < position:
                content.append("/* source lines omitted from patch */")
                old_line += 1
            in_hunk = True
        elif in_hunk and line.startswith((" ", "-")):
            content.append(line[1:])
            old_line += 1
        elif in_hunk and (line.startswith("+") or line.startswith("\\ No newline")):
            continue
        elif in_hunk and line:
            raise ValueError("Unexpected line in patch: " + line)
    flush()


@unittest.skipUnless(shutil.which("git"), "git required")
class MadeiraCompatibilityBackportsTests(unittest.TestCase):
    def test_exact_upstream_hunks_apply_once_to_pinned_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            patch = PATCH.read_text(encoding="utf-8")
            make_pinned_source_fixtures(patch, checkout)
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            subprocess.run(["git", "-C", str(checkout), "apply", "--check", str(PATCH)], check=True)
            subprocess.run(["git", "-C", str(checkout), "apply", str(PATCH)], check=True)
            subprocess.run(["git", "-C", str(checkout), "apply", "--reverse",
                            "--check", str(PATCH)], check=True)
            reapply = subprocess.run(
                ["git", "-C", str(checkout), "apply", "--check", str(PATCH)],
                capture_output=True, text=True, check=False
            )
            self.assertNotEqual(reapply.returncode, 0)
            wineserver = (checkout / TARGETS[2]).read_text(encoding="utf-8")
            audio = (checkout / TARGETS[1]).read_text(encoding="utf-8")
            wine = (checkout / TARGETS[0]).read_text(encoding="utf-8")
            self.assertIn("mem_size_t size = round_size(", wineserver)
            self.assertIn("ios_engine_period(void)", audio)
            self.assertIn('getenv( "MADEIRA_AUDIO_IO_US" )', audio)
            self.assertIn("setPreferredIOBufferDuration", wine)
            self.assertIn("vcrtDocsSource", wine)
            self.assertIn("vcrtHome[[dll lowercaseString]]", wine)

    def test_only_expected_madeira_sources_change(self):
        patch = PATCH.read_text(encoding="utf-8")
        self.assertEqual(patch.count("diff --git "), len(TARGETS))
        for name in TARGETS:
            self.assertIn("diff --git a/" + name + " b/" + name, patch)
        fetch = FETCH.read_text(encoding="utf-8")
        self.assertIn('git -C "$DEST" apply --reverse --check "$COMPAT_PATCH"', fetch)
        self.assertIn('git -C "$DEST" apply --check "$COMPAT_PATCH"', fetch)

    def test_settings_exposes_owner_supplied_compatibility_folder(self):
        settings = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
        self.assertIn('appendingPathComponent("vcruntime", isDirectory: true)', settings)
        self.assertIn('settingsSection(title: tr("Windows compatibility"))', settings)
        self.assertNotIn("vc_redist.x64.exe", settings)


if __name__ == "__main__":
    unittest.main()
