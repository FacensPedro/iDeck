"""Cache keys of the slow native stages follow the sources each stage compiles."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/native_cache_fingerprints.sh"
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text()


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                   check=True, capture_output=True)


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.md = Path(self.folder.name) / "Madeira"
        files = {
            "app/Madeira/WineProcessBridge.m": "bridge", "build/ntdll-unix/loader_ios.c": "loader",
            "build/wine-i386/build.sh": "i386", "build/gnutls-ios/build.sh": "gnutls",
            "build/ffmpeg/build.sh": "ffmpeg", "build/freetype-ios/build.sh": "freetype",
            "build/moltenvk-ios/build.sh": "mvk", "build/mesa-ios/build.sh": "mesa",
        }
        for name, body in files.items():
            path = self.md / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        (self.md / ".gitignore").write_text("wine/\ndxmt/\n")
        git(self.md, "init", "-q")
        git(self.md, "add", "-A")
        git(self.md, "commit", "-qm", "pin")
        for sub in ("wine", "dxmt"):
            repo = self.md / sub
            (repo / "dlls").mkdir(parents=True)
            (repo / "dlls/source.c").write_text(sub)
            git(repo, "init", "-q")
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", "pin")

    def tearDown(self):
        self.folder.cleanup()

    def prints(self) -> dict:
        out = subprocess.run(["bash", str(SCRIPT), str(self.md)], check=True, capture_output=True, text=True).stdout
        return dict(line.split("=", 1) for line in out.split())

    def test_ios_only_patches_keep_every_stage(self):
        before = self.prints()
        (self.md / "app/Madeira/WineProcessBridge.m").write_text("patched bridge")
        (self.md / "build/ntdll-unix/loader_ios.c").write_text("patched loader")
        (self.md / "app/Madeira/nls").mkdir()
        (self.md / "app/Madeira/nls/c_850.nls").write_text("table")
        self.assertEqual(self.prints(), before)

    def test_a_wine_patch_rebuilds_only_the_i386_farm(self):
        before = self.prints()
        (self.md / "wine/dlls/source.c").write_text("patched")
        after = self.prints()
        self.assertNotEqual(after["i386"], before["i386"])
        self.assertEqual((after["deps"], after["gl"]), (before["deps"], before["gl"]))

    def test_new_files_and_build_scripts_count(self):
        before = self.prints()
        (self.md / "dxmt/new.cpp").write_text("new")
        self.assertNotEqual(self.prints()["i386"], before["i386"])
        (self.md / "build/ffmpeg/build.sh").write_text("changed")
        (self.md / "build/mesa-ios/build.sh").write_text("changed")
        after = self.prints()
        self.assertNotEqual(after["deps"], before["deps"])
        self.assertNotEqual(after["gl"], before["gl"])

    def test_a_missing_submodule_is_an_error(self):
        import shutil
        shutil.rmtree(self.md / "dxmt")
        result = subprocess.run(["bash", str(SCRIPT), str(self.md)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


class WorkflowKeyTests(unittest.TestCase):
    def test_fingerprints_are_computed_after_the_fetch_and_before_the_caches(self):
        fetch = WORKFLOW.index("run: bash scripts/fetch_madeira_sources.sh")
        fingerprint = WORKFLOW.index("bash scripts/native_cache_fingerprints.sh vendor/Madeira")
        self.assertLess(fetch, fingerprint)
        for key in ("steps.native_fp.outputs.deps", "steps.native_fp.outputs.gl", "steps.native_fp.outputs.i386"):
            self.assertLess(fingerprint, WORKFLOW.index(key))

    def test_slow_stage_keys_no_longer_hash_the_fetch_script(self):
        for line in WORKFLOW.splitlines():
            if "key: madeira-deps-" in line or "key: madeira-gl-vulkan-" in line or "key: madeira-i386-farm-" in line:
                self.assertNotIn("fetch_madeira_sources.sh", line)
                self.assertNotIn("patches/**", line)


class ParallelArchiveTests(unittest.TestCase):
    def test_archives_are_compressed_in_separate_processes(self):
        split = (ROOT / "scripts/split_runtime_downloads.py").read_text()
        self.assertIn("concurrent.futures.ProcessPoolExecutor", split)


if __name__ == "__main__":
    unittest.main()
