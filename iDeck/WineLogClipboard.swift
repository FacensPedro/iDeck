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
            // The copy is compacted: repeated lines are folded, so it is much smaller.
            let raw = try Data(contentsOf: source)
            try Data(LogCompactor.compact(String(decoding: raw, as: UTF8.self)).utf8)
                .write(to: destination, options: .atomic)
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

    /// Puts `text` on the pasteboard as a .txt file named `name`.
    static func copyText(_ text: String, named name: String) throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try Data(LogCompactor.compact(text).utf8).write(to: destination, options: .atomic)
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            completion(destination, false, nil)
            return nil
        }
        UIPasteboard.general.setItemProviders([provider], localOnly: true, expirationDate: nil)
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

        return Content(text: LogCompactor.compact(text), truncated: truncated)
    }
}

/// Makes iDeck's logs (Wine log, iDeck log, bug report) smaller and less repetitive.
///
/// A database (.sql/SQLite) would not be smaller: the text is the same and it adds
/// pages and indexes. What shrinks a log is (1) leaving out lines that repeat apart
/// from numbers, addresses, thread ids and times, and (2) compressing what is kept
/// on disk. Copied and shared logs stay readable .txt (compacted); logs kept only as
/// history (the previous Wine log) are stored compacted and compressed (.lzfse).
enum LogCompactor {
    /// A line seen more than this many times (anywhere in the log) is left out after
    /// that, and counted in the summary at the end.
    static let maximumRepeats = 3

    /// The text without long runs and endless repeats:
    /// - a run of lines that differ only in numbers/addresses becomes the first one
    ///   and "↑ repeated N more times";
    /// - a line already written `maximumRepeats` times is left out; the most
    ///   repeated ones are listed at the end with their counts.
    static func compact(_ text: String) -> String {
        var out: [String] = []
        out.reserveCapacity(1024)
        var seen: [String: Int] = [:]
        var dropped: [String: (line: Substring, count: Int)] = [:]
        var lastKey: String?
        var run = 0
        func flushRun() {
            if run > 0 { out.append("↑ repeated \(run) more time\(run == 1 ? "" : "s")") }
            run = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let key = normalized(line)
            if key == lastKey { run += 1; continue }
            flushRun()
            lastKey = key
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count <= maximumRepeats {
                out.append(String(line))
            } else {
                dropped[key, default: (line, 0)].count += 1
            }
        }
        flushRun()
        var result = out.joined(separator: "\n")
        if !dropped.isEmpty {
            let top = dropped.values.sorted { $0.count > $1.count }.prefix(40)
            result += "\n\n[iDeck] Lines left out after \(maximumRepeats) appearances (×count):\n"
            result += top.map { "(×\($0.count)) \($0.line)" }.joined(separator: "\n")
            if dropped.count > top.count { result += "\n… and \(dropped.count - top.count) more kinds of repeated lines" }
            result += "\n"
        }
        return result
    }

    /// The line with timestamps, hex addresses, numbers and thread ids replaced, so
    /// repeats that differ only in them share a key.
    static func normalized(_ line: Substring) -> String {
        var key = ""
        key.reserveCapacity(line.count)
        var inNumber = false
        for c in line.unicodeScalars {
            let isDigit = c.properties.numericType != nil
            let isHexAfterZeroX = inNumber && (("a"..."f").contains(c) || ("A"..."F").contains(c) || c == "x")
            if isDigit || isHexAfterZeroX {
                if !inNumber { key.unicodeScalars.append("#") }
                inNumber = true
            } else {
                inNumber = false
                key.unicodeScalars.append(c)
            }
        }
        return key
    }

    /// Writes `text` compacted and LZFSE-compressed (read back with `readCompressed`).
    static func writeCompressed(_ text: String, to url: URL) throws {
        let data = Data(compact(text).utf8) as NSData
        try data.compressed(using: .lzfse).write(to: url, options: .atomic)
    }

    static func readCompressed(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) as NSData,
              let plain = try? data.decompressed(using: .lzfse) else { return nil }
        return String(decoding: plain as Data, as: UTF8.self)
    }
}
