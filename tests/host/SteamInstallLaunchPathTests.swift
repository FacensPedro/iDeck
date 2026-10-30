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

        // Installed-size accounting reads the actual game files, not the
        // compressed Steam CDN journal or an unrelated symlink destination.
        let installFolder = root.appendingPathComponent("InstalledGame", isDirectory: true)
        let contentFolder = installFolder.appendingPathComponent("Content", isDirectory: true)
        try manager.createDirectory(at: contentFolder, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8192).write(
            to: contentFolder.appendingPathComponent("base.dat"))
        try Data(repeating: 0x51, count: 2048).write(
            to: installFolder.appendingPathComponent("game.exe"))
        let externalLink = contentFolder.appendingPathComponent("external.dat")
        try manager.createSymbolicLink(at: externalLink, withDestinationURL: outside)
        let nestedAlias = installFolder.appendingPathComponent("Alias")
        try manager.createSymbolicLink(at: nestedAlias, withDestinationURL: contentFolder)
        assert(SteamInstallFiles.logicalInstalledSize(at: installFolder) == 10_240)
        assert(SteamInstallFiles.logicalInstalledSize(at: externalLink) == nil)
        assert(SteamInstallFiles.logicalInstalledSize(
            at: installFolder.appendingPathComponent("Missing")) == nil)
        // A file can contain several GiB of logical game data, independent
        // of its compressed CDN transfer size or APFS physical allocation.
        let large = installFolder.appendingPathComponent("large-game.data")
        assert(manager.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        handle.truncateFile(atOffset: 4 * 1024 * 1024 * 1024)
        handle.closeFile()
        assert(SteamInstallFiles.logicalInstalledSize(at: installFolder) ==
            4 * 1024 * 1024 * 1024 + 10_240)

        print("PASS: Steam launch executable and workingdir paths are case-insensitive, bounded and sandbox-safe")
    }
}
