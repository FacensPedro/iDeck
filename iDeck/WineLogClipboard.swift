import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

enum WineLogClipboard {
    static let maximumCopiedBytes = 4 * 1024 * 1024

    struct Content: Sendable {
        let text: String
        let truncated: Bool
    }

    enum ReadError: Error {
        case invalidFile
        case empty
    }

    #if canImport(UIKit)
    @MainActor
    static func copyFile(from source: URL, name: String = "Wine-log") async throws {
        let snapshot = try await Task.detached(priority: .utility) {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReadError.invalidFile }
            guard (values.fileSize ?? 0) > 0 else { throw ReadError.empty }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(name + "-" + UUID().uuidString + ".txt")
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }.value
        let provider = NSItemProvider()
        provider.suggestedName = name + ".txt"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            completion(snapshot, false, nil)
            return nil
        }
        UIPasteboard.general.setItemProviders([provider], localOnly: true, expirationDate: nil)
    }

    /// Writes `text` to a .txt file and puts that file on the clipboard.
    @MainActor
    static func copyText(_ text: String, name: String) async throws {
        let file = try await Task.detached(priority: .utility) { () -> URL in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-source-" + UUID().uuidString + ".txt")
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        }.value
        defer { try? FileManager.default.removeItem(at: file) }
        try await copyFile(from: file, name: name)
    }

    #endif

    static func read(from url: URL) throws -> Content {
        let attributes = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true,
              attributes.isSymbolicLink != true else {
            throw ReadError.invalidFile
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalSize = try handle.seekToEnd()
        guard totalSize > 0 else { throw ReadError.empty }

        let maximum = UInt64(maximumCopiedBytes)
        let truncated = totalSize > maximum
        let start = truncated ? totalSize - maximum : 0
        try handle.seek(toOffset: start)
        guard let data = try handle.readToEnd(), !data.isEmpty else {
            throw ReadError.empty
        }

        var text = String(decoding: data, as: UTF8.self)
        if truncated {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            text = "[iDeck] Only the newest 4 MiB of this Wine log were copied. Use Share Wine log for the entire file.\n\n" + text
        }

        return Content(text: text, truncated: truncated)
    }
}
