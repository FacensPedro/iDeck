import Foundation

@main
struct SteamInstallLaunchPathTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("ideck-steam-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }

        let binaryDir = root.appendingPathComponent("Binaries/Win64", isDirectory: true)
        let executable = binaryDir.appendingPathComponent("SampleGame.exe")
        try manager.createDirectory(at: binaryDir, withIntermediateDirectories: true)
        try Data([0x4d, 0x5a, 0x90]).write(to: executable)

        func check(_ relative: String, executable expected: Bool) -> URL? {
            SteamInstallFiles.resolveLaunchPath(relative, root: root, executable: expected)
        }

        assert(check("Binaries/Win64/SampleGame.exe", executable: true) != nil)
        assert(check("binaries\\WIN64\\samplegame.EXE", executable: true) != nil)
        assert(check("./Binaries/Win64/SampleGame.exe", executable: true) != nil)
        assert(check("Binaries/Win64", executable: false) != nil)
        assert(check("binaries\\win64", executable: false) != nil)
        assert(check(".", executable: false)?.standardizedFileURL == root.standardizedFileURL)
        assert(check("", executable: false)?.standardizedFileURL == root.standardizedFileURL)

        assert(check("../Outside.exe", executable: true) == nil)
        assert(check("C:\\Windows\\System32\\cmd.exe", executable: true) == nil)
        assert(check("Binaries/Win64/Missing.exe", executable: true) == nil)
        assert(check("Binaries/Win64/SampleGame.txt", executable: true) == nil)
        assert(check("Binaries/Win64/SampleGame.exe", executable: false) == nil)
        assert(check("Binaries/Win64", executable: true) == nil)

        let outside = manager.temporaryDirectory.appendingPathComponent(
            "ideck-launch-outside-\(UUID().uuidString).exe")
        defer { try? manager.removeItem(at: outside) }
        try Data([0x4d, 0x5a]).write(to: outside)
        let symlink = root.appendingPathComponent("Unsafe.exe")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: outside)
        assert(check("Unsafe.exe", executable: true) == nil)

        let directoryAlias = root.appendingPathComponent("Alias")
        try manager.createSymbolicLink(at: directoryAlias, withDestinationURL: binaryDir)
        assert(check("Alias/SampleGame.exe", executable: true) == nil)

        print("PASS: Steam launch executable and workingdir paths are case-insensitive, bounded and sandbox-safe")
    }
}
