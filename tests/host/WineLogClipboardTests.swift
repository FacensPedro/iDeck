import Foundation

@main
enum WineLogClipboardTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("ideck-wine-copy-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let log = root.appendingPathComponent("madeira-log.txt")
        try Data("Wine initialized\nGame started\n".utf8).write(to: log)
        let small = try WineLogClipboard.read(from: log)
        precondition(!small.truncated)
        precondition(small.text == "Wine initialized\nGame started\n")

        try Data().write(to: log)
        do {
            _ = try WineLogClipboard.read(from: log)
            preconditionFailure("Empty Wine logs must be rejected")
        } catch WineLogClipboard.ReadError.empty {
        }

        var large = Data("Old error should not appear\n".utf8)
        large.append(Data(repeating: 0x78, count: WineLogClipboard.maximumCopiedBytes + 512))
        large.append(Data("\nLast game error: missing DLL\n".utf8))
        try large.write(to: log)
        let newest = try WineLogClipboard.read(from: log)
        precondition(newest.truncated)
        precondition(newest.text.contains("newest 4 MiB"))
        precondition(newest.text.contains("Last game error: missing DLL"))
        precondition(!newest.text.contains("Old error should not appear"))

        let alias = root.appendingPathComponent("alias.txt")
        try manager.createSymbolicLink(at: alias, withDestinationURL: log)
        do {
            _ = try WineLogClipboard.read(from: alias)
            preconditionFailure("Symlinks must not be copied to the clipboard")
        } catch WineLogClipboard.ReadError.invalidFile {
        }
        print("PASS: Wine clipboard copies complete small logs and bounded large-log tails")
    }
}
