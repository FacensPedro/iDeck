"""Host regression coverage for Madeira Dock's separate first-run installer session."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "iDeck/SteamDockInstallers.swift"
COORDINATOR = ROOT / "iDeck/SystemCoordinator.swift"
NATIVE = ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm"
PROJECT = ROOT / "iDeck.xcodeproj/project.pbxproj"

HARNESS = r'''
import Foundation

struct DockGame {
    var id: Int
    var installDir: String
    var library: String
    var customExecutables: Bool
    var windowsInstallPath: String {
        "C:\\" + (library + "/common/" + installDir).replacingOccurrences(of: "/", with: "\\")
    }
}
enum SteamInstallPaths {
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"
}
enum MadeiraDock {
    static func stageHost() throws -> URL { URL(fileURLWithPath: "/tmp/dockhost.exe") }
}

@main
struct Tests {
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() { fatalError(label) }
    }

    static func pe(_ machine: UInt16) -> Data {
        var data = Data(repeating: 0, count: 512)
        data[0] = 0x4d; data[1] = 0x5a; data[60] = 0x80
        data[128] = 0x50; data[129] = 0x45
        data[132] = UInt8(truncatingIfNeeded: machine)
        data[133] = UInt8(truncatingIfNeeded: machine >> 8)
        return data
    }

    static func main() throws {
        let script = """
        "InstallScript" {
          "Run Process" {
            "Setup" {
              "Process 1" "%INSTALLDIR%\\\\redist\\\\setup.exe"
              "Command 1" "/silent"
            }
            "Injection" {
              "Process 1" "%INSTALLDIR%\\\\redist\\\\setup.exe"
              "Command 1" "/quiet & calc"
            }
          }
          "Run Process" {
            "Second" {
              "HasRunKey" "HKEY_CURRENT_USER\\\\SOFTWARE\\\\Fixture"
              "Process 1" "%INSTALLDIR%\\\\redist\\\\second.exe"
            }
          }
        }
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = root.appendingPathComponent("drive_c")
        let game = DockGame(id: 321, installDir: "Fixture", library: SteamInstallPaths.libraryRelative, customExecutables: false)
        let gameFolder = drive.appendingPathComponent(SteamInstallPaths.libraryRelative + "/common/Fixture")
        let redist = gameFolder.appendingPathComponent("redist")
        try FileManager.default.createDirectory(at: redist, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("windows/system32"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: gameFolder.appendingPathComponent("installscript.vdf"))
        try pe(0x8664).write(to: redist.appendingPathComponent("setup.exe"))
        try pe(0x8664).write(to: drive.appendingPathComponent("windows/system32/cmd.exe"))
        let parsed = DockInstallScripts.processes(script: Data(script.utf8), installDir: game.windowsInstallPath, appID: game.id)
        check(parsed.map(\.run.name) == ["setup", "second"], "repeated Run Process and unsafe arguments")
        check(IDeckSteamDockInstallers.resolve("C:\\..\\setup.exe", drive: drive) == nil, "traversal refused")
        check(IDeckSteamDockInstallers.resolve("C:\\redist\\evil&x.exe", drive: drive) == nil, "cmd injection refused")
        check(IDeckSteamDockInstallers.resolve(
            game.windowsInstallPath + "\\redist\\SETUP.EXE", drive: drive) != nil, "case insensitive resolver")
        try "WINE REGISTRY Version 2\n\n".write(to: root.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n\n".write(to: root.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        // The absent second.exe must be reported, never marked complete.
        do {
            _ = try IDeckSteamDockInstallers.stage(appID: 321, game: game, prefix: root)
            fatalError("missing second installer silently ignored")
        } catch {
            check(error.localizedDescription.contains("file missing"), "missing prerequisite reported")
        }
        try pe(0x8664).write(to: redist.appendingPathComponent("second.exe"))
        let stage = try IDeckSteamDockInstallers.stage(appID: 321, game: game, prefix: root)
        check(stage?.count == 2, "two valid setup processes")
        let result = drive.appendingPathComponent("ideck-dock-installers-321.result")
        try "begin 2\nstart 1 setup\nexit 1 0\nstart 2 second\nexit 2 123\nend\n"
            .write(to: result, atomically: true, encoding: .utf8)
        let message = try IDeckSteamDockInstallers.absorb(appID: 321, prefix: root)
        check(message?.contains("1 of 2") == true, "only successful installer acknowledged")
        let registry = try String(contentsOf: root.appendingPathComponent("system.reg"), encoding: .utf8)
        check(DockInstallScripts.marked(parsed[0].run, in: registry), "successful setup recorded")
        let userRegistry = try String(contentsOf: root.appendingPathComponent("user.reg"), encoding: .utf8)
        check(!DockInstallScripts.marked(parsed[1].run, in: userRegistry), "failed setup not recorded")
        let retry = try IDeckSteamDockInstallers.stage(appID: 321, game: game, prefix: root)
        check(retry?.count == 1, "failed prerequisite retries without rerunning successful one")
        try "begin 1\nstart 1 second\nexit 1 0\n"
            .write(to: result, atomically: true, encoding: .utf8)
        let incomplete = try IDeckSteamDockInstallers.absorb(appID: 321, prefix: root)
        check(incomplete?.contains("interrupted") == true, "interrupted batch is not committed")
        print("PASS: Steam Dock script parsing, safe paths, setup sessions and registry receipts")
    }
}
'''


class SteamDockInstallerTests(unittest.TestCase):
    def test_host_swift(self):
        swiftc = shutil.which("swiftc")
        if not swiftc:
            self.skipTest("swiftc unavailable")
        with tempfile.TemporaryDirectory() as directory:
            harness = pathlib.Path(directory) / "SteamDockHostTests.swift"
            harness.write_text(HARNESS, encoding="utf-8")
            binary = pathlib.Path(directory) / "steam-dock-tests"
            subprocess.run([swiftc, "-parse-as-library", "-swift-version", "5",
                            str(SOURCE), str(harness), "-o", str(binary)],
                           check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=20)

    def test_wiring_and_security(self):
        coordinator = COORDINATOR.read_text(encoding="utf-8")
        bridge = NATIVE.read_text(encoding="utf-8")
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn("IDeckSteamDockInstallers.stage(", coordinator)
        self.assertIn("IDeckSteamDockInstallers.absorb(", coordinator)
        self.assertIn('setWindowsStatus("Installing Steam prerequisites...")', coordinator)
        self.assertIn("!ideck_wineserver_running()", coordinator)
        self.assertIn("No direct DRM fallback was attempted.", coordinator)
        self.assertIn("allowedSystemCMD", bridge)
        self.assertIn('@"windows/system32/cmd.exe"', bridge)
        self.assertEqual(project.count("path = SteamDockInstallers.swift;"), 1)
        self.assertEqual(project.count("/* SteamDockInstallers.swift in Sources */,"), 1)


if __name__ == "__main__":
    unittest.main()
