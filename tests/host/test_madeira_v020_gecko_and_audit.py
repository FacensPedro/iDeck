import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GECKO = (ROOT / "iDeck/WineGeckoRuntime.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "iDeck.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
AUDITOR = ROOT / "scripts/audit_madeira_v020_pe.py"

spec = importlib.util.spec_from_file_location("madeira_v020_auditor", AUDITOR)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MadeiraV020GeckoTests(unittest.TestCase):
    def test_official_madeira_020_wine_gecko_pins_and_secure_cache(self):
        self.assertIn('static let version = "2.47.4"', GECKO)
        self.assertIn("26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6", GECKO)
        self.assertIn("e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f", GECKO)
        self.assertIn("https://dl.winehq.org/wine/wine-gecko/", GECKO)
        self.assertIn('prefix.appendingPathComponent(".cache/wine"', GECKO)
        self.assertIn("digest.finalize()", GECKO)
        self.assertIn("settings.allowsExpensiveNetworkAccess = false", GECKO)
        self.assertIn("settings.allowsConstrainedNetworkAccess = false", GECKO)
        self.assertIn("wine_process_is_running() == 0, wineserver_is_running() == 0", GECKO)
        self.assertIn("guard WineGeckoRuntime.valid(downloaded, for: pin)", GECKO)
        self.assertIn('".ideck-invalid-backup"', GECKO)
        self.assertIn('try? fm.moveItem(at: backup, to: destination)', GECKO)
        self.assertNotIn("fileDataRepresentation(", GECKO)

    def test_gecko_prepared_from_prefix_even_without_steam_signin(self):
        self.assertIn("WineGeckoRuntime.prepareInBackground(prefix: MadeiraDock.prefix)", COORDINATOR)
        self.assertLess(
            COORDINATOR.index("WineGeckoRuntime.prepareInBackground"),
            COORDINATOR.index("guard steamComponentsTask == nil"),
        )
        self.assertIn("WineGeckoRuntime.swift in Sources", PROJECT)
        self.assertIn("WineGeckoRuntime.swift */ = {isa = PBXFileReference;", PROJECT)


class MadeiraV020DLLAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.upstream = Path(self.temp.name) / "Madeira"
        self.ideck = Path(self.temp.name) / "iDeck"
        self.upstream.mkdir()
        self.ideck.mkdir()

    def place(self, root, directory, name, contents=b"MZtest"):
        folder = root / directory
        folder.mkdir(exist_ok=True)
        (folder / name).write_bytes(contents)

    def test_dlls_missing_and_changed_are_separate(self):
        self.place(self.upstream, "arm64ec-windows", "kernelbase.dll", b"new")
        self.place(self.upstream, "arm64ec-windows", "sechost.dll", b"same")
        self.place(self.upstream, "arm64ec-windows", "dcomp.dll", b"update")
        self.place(self.ideck, "arm64ec-windows", "kernelbase.dll", b"old")
        self.place(self.ideck, "arm64ec-windows", "sechost.dll", b"same")
        report = module.audit(self.upstream, self.ideck, graphics="d3d11", wow64=False)
        self.assertEqual(report["missing"], ["arm64ec-windows/dcomp.dll"])
        self.assertEqual(report["different_binary"], ["arm64ec-windows/kernelbase.dll"])
        self.assertEqual(report["identical_binary"], 1)

    def test_d3d12_and_wow64_profile_are_explicit(self):
        self.place(self.upstream, "arm64ec-windows", "d3d12.dll")
        self.place(self.upstream, "i386-windows", "ntdll.dll")
        d11 = module.audit(self.upstream, self.ideck, graphics="d3d11", wow64=False)
        self.assertEqual(d11["missing"], [])
        self.assertIn("arm64ec-windows/d3d12.dll", d11["optional_profile_exclusions"])
        d12 = module.audit(self.upstream, self.ideck, graphics="d3d12", wow64=True)
        self.assertIn("arm64ec-windows/d3d12.dll", d12["missing"])
        self.assertIn("i386-windows/ntdll.dll", d12["missing"])


if __name__ == "__main__":
    unittest.main()
