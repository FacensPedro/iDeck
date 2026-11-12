import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

from support import ROOT, repo_text


class SetupDownloadsRuntimeTests(unittest.TestCase):
    def test_wine_farms_are_split_out_of_the_ipa(self):
        with tempfile.TemporaryDirectory() as work:
            app = Path(work) / "iDeck.app"
            for folder in ("arm64ec-windows", "aarch64-windows", "i386-windows", "nls", "compat/love",
                           "vulkan/arm64ec-windows", "gl", "wine-mono/bin", "vcruntime-bundle", "d3d12"):
                (app / folder).mkdir(parents=True)
            for name in ("arm64ec-windows/ntdll.dll", "aarch64-windows/wow64.dll", "i386-windows/ntdll.dll",
                         "nls/locale.nls", "compat/love/lua51.dll", "vulkan/arm64ec-windows/winevulkan.dll",
                         "gl/libMoltenVK.dylib", "wine-mono/bin/libmono-2.0-x86.dll",
                         "vcruntime-bundle/msvcp140.dll", "d3d12/libmetalirconverter.dylib"):
                (app / name).write_bytes(b"MZ" + name.encode())
            out = Path(work) / "out"
            subprocess.run([sys.executable, str(ROOT / "scripts/split_runtime_downloads.py"), "--app", str(app),
                            "--out", str(out), "--repo", "FacensPedro/iDeck"], check=True, capture_output=True)
            left = sorted(p.name for p in app.iterdir())
            self.assertEqual(left, ["d3d12", "gl", "iDeckRuntimeDownloads.plist"])
            manifest = plistlib.loads((app / "iDeckRuntimeDownloads.plist").read_bytes())
            self.assertEqual([p["id"] for p in manifest["packages"]], ["wine-x64", "wine-x86"])
            for package in manifest["packages"]:
                self.assertTrue(package["url"].startswith(
                    f"https://github.com/FacensPedro/iDeck/releases/download/{manifest['tag']}/"))
            x64 = next(out.glob("wine-x64-*.tar.xz"))
            with tarfile.open(x64, "r:xz") as tar:
                names = tar.getnames()
            self.assertIn("arm64ec-windows/ntdll.dll", names)
            self.assertIn("vulkan/arm64ec-windows/winevulkan.dll", names)
            self.assertNotIn("i386-windows/ntdll.dll", names)

    def test_bridge_reads_downloaded_runtime(self):
        script = repo_text("scripts/apply_madeira_runtime_root.py")
        self.assertIn('stringByAppendingPathComponent:@"MadeiraRuntime"', script)
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_runtime_root.py" "$DEST"', repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"scripts/apply_madeira_runtime_root.py"', repo_text("scripts/madeira_native_kit.py"))
        self.assertIn("ideck_runtime_root()", repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm"))
        self.assertIn('setenv("MADEIRA_DATA_DIR", bundlePath.UTF8String, 1);', script)
        self.assertIn('getenv( "MADEIRA_DATA_DIR" )', script)
        self.assertIn('build/ntdll-unix/loader_ios.c', script)
        self.assertIn('data_dir = strdup( exe_path );  /* NLS files at <bundle>/nls/ */', script)
        build = repo_text("scripts/build_ipa.sh")
        self.assertIn("scripts/split_runtime_downloads.py", build)

    def test_initial_setup_installs_the_runtime(self):
        view = repo_text("iDeck/MainView.swift")
        for step in ("MadeiraRuntime.install(package.id)", "coordinator.installMadeiraDock()", "MadeiraRuntime.needsDownload"):
            self.assertIn(step, view)
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* MadeiraRuntime.swift in Sources */"), 2)

    def test_downloads_report_real_progress(self):
        observed = repo_text("iDeck/ObservedDownload.swift")
        self.assertIn("URLSession(configuration: configuration, delegate: download, delegateQueue: nil)", observed)
        self.assertIn("didWriteData", observed)
        self.assertIn("ObservedDownload.run(", repo_text("iDeck/MadeiraRuntime.swift"))
        self.assertNotIn("URLSession.shared.download(from:", repo_text("iDeck/MadeiraRuntime.swift"))
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("/* ObservedDownload.swift in Sources */"), 2)

    def test_workflow_keeps_runtime_in_the_ipa(self):
        workflow = repo_text(".github/workflows/ios.yml")
        self.assertNotIn("Publish Windows runtime downloads", workflow)
        self.assertNotIn("iDeck Windows runtime $TAG", workflow)
        self.assertIn("IDECK_SPLIT_RUNTIME: '0'", workflow)


if __name__ == "__main__":
    unittest.main()
