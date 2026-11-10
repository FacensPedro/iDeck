import Foundation

@main struct RuntimeFileUtilitiesTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("checksum.bin")
        let cases: [(Data, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (Data(repeating: 97, count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        ]
        for (data, expected) in cases {
            try data.write(to: file)
            precondition(try! FileChecksum.sha256(of: file) == expected)
        }
        // Cross the one-MiB read boundary with a non-aligned tail.
        let large = Data(repeating: 97, count: 2_097_169)
        try large.write(to: file)
        precondition(try! FileChecksum.sha256(of: file) == "c2273a45bd6d19d2714b8279b1fd1123bb746e7f7f6331085fb6ecaa30164546")
        try fm.removeItem(at: file)
        do { _ = try FileChecksum.sha256(of: file); preconditionFailure("Missing file accepted") }
        catch {}

        let drive = root.appendingPathComponent("drive_c")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        precondition(WindowsDrivePath.relative(drive.appendingPathComponent("Games/My Game/a.exe"), drive: drive) == "C:\\Games\\My Game\\a.exe")
        precondition(WindowsDrivePath.relative(drive.appendingPathComponent("Games/../á.exe"), drive: drive) == "C:\\á.exe")
        precondition(WindowsDrivePath.relative(drive, drive: drive) == nil)
        precondition(WindowsDrivePath.relative(root.appendingPathComponent("drive_c-other/a.exe"), drive: drive) == nil)
        precondition(WindowsDrivePath.relative(drive.appendingPathComponent("../outside.exe"), drive: drive) == nil)
        let link = drive.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        precondition(WindowsDrivePath.relative(link.appendingPathComponent("game.exe"), drive: drive) == "C:\\linked\\game.exe")
        print("PASS: SHA-256 known vectors, multi-block files, read errors, drive boundaries and lexical links")
    }
}
