"""The EA app and Ubisoft Connect install without Wine: their installers are
opened by LauncherArchiveExtractor.c. The extractor is built here when a C
compiler is present (IDECK_LAUNCHER_EXTRACTOR names an already built one). With
IDECK_LAUNCHER_INSTALLERS naming a folder holding UbisoftConnectInstaller.exe,
EAappInstaller.exe and the EA app's .msi, the real installers are extracted too."""
import split_sources  # noqa: F401  (iDeck 3.0 split files)
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MSPACK = ["cabd", "system", "mszipd", "lzxd", "qtmd", "crc32"]


def build(folder):
    built = os.environ.get("IDECK_LAUNCHER_EXTRACTOR")
    if built:
        return built
    compiler = shutil.which("cc") or shutil.which("clang")
    if not compiler:
        return None
    objects = []
    sources = [ROOT / f"iDeck/ThirdParty/libmspack/{n}.c" for n in MSPACK]
    sources += [ROOT / "iDeck/NativeRuntime/LauncherArchiveExtractor.c", ROOT / "tests/host/LauncherArchiveHostTests.c"]
    for source in sources:
        target = Path(folder) / (source.stem + ".o")
        subprocess.run([compiler, "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra",
                        "-I", str(ROOT / "iDeck/ThirdParty/libmspack"), "-I", str(ROOT),
                        "-c", str(source), "-o", str(target)], check=True, capture_output=True)
        objects.append(str(target))
    program = str(Path(folder) / "launcher-extractor")
    subprocess.run([compiler, *objects, "-lz", "-o", program], check=True, capture_output=True)
    return program


class LauncherArchiveExtractorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.mkdtemp()
        try:
            cls.program = build(cls.folder)
        except subprocess.CalledProcessError as error:
            raise AssertionError(error.stderr.decode())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.folder, ignore_errors=True)

    def run_tool(self, kind, source, target):
        return subprocess.run([self.program, kind, str(source), str(target)], capture_output=True, text=True)

    def test_refuses_files_that_are_not_installers(self):
        if not self.program:
            self.skipTest("no C compiler")
        junk = Path(self.folder) / "junk.exe"
        junk.write_bytes(b"MZ" + b"\0" * 9000)
        out = Path(self.folder) / "out"
        out.mkdir(exist_ok=True)
        for kind in ("nsis", "msi"):
            result = self.run_tool(kind, junk, out)
            self.assertNotEqual(result.returncode, 0, kind)
            self.assertTrue(result.stdout.startswith("-"), result.stdout)
        self.assertEqual(list(out.iterdir()), [])

    def test_real_installers(self):
        folder = os.environ.get("IDECK_LAUNCHER_INSTALLERS")
        if not self.program or not folder:
            self.skipTest("IDECK_LAUNCHER_INSTALLERS not set")
        folder = Path(folder)
        ubisoft = Path(self.folder) / "ubisoft"
        ubisoft.mkdir()
        result = self.run_tool("nsis", folder / "UbisoftConnectInstaller.exe", ubisoft)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((ubisoft / "UbisoftConnect.exe").is_file())
        self.assertTrue((ubisoft / "upc.exe").is_file())
        self.assertFalse(any("PLUGINSDIR" in str(p) for p in ubisoft.rglob("*")))
        manifest = Path(self.folder) / "manifest.xml"
        result = self.run_tool("burn", folder / "EAappInstaller.exe", manifest)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("DownloadUrl=", manifest.read_text(encoding="utf-8-sig"))
        package = next(folder.glob("*.msi"))
        ea = Path(self.folder) / "ea"
        ea.mkdir()
        result = self.run_tool("msi", package, ea)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((ea / "Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe").is_file())


class SwiftUsesTheExtractorTests(unittest.TestCase):
    def test_store_clients_install_without_wine(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        install = coordinator[coordinator.index("func installDefaultStoreClients("):]
        install = install[:install.index("\n    }\n")]
        self.assertIn("StoreClient.installWithoutWine(client)", install)
        self.assertNotIn("launchWindowsExecutable", install)
        self.assertNotIn("ideck:store-setup", coordinator)
        self.assertIn("ideck_nsis_extract(source.path, target.path", coordinator)
        self.assertIn("ideck_msi_extract(source.path, target.path", coordinator)
        self.assertIn('url.host == "origin-a.akamaihd.net"', coordinator)
        bridging = (ROOT / "iDeck/iDeck-Bridging-Header.h").read_text()
        self.assertIn('#import "NativeRuntime/LauncherArchiveExtractor.h"', bridging)
        project = (ROOT / "iDeck.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count("LauncherArchiveExtractor.c in Sources"), 2)


if __name__ == "__main__":
    unittest.main()
