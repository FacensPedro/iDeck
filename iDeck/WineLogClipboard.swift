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
    static let maximumRepeats = 2

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
        var progressShown = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // A program's progress ("Loading 1%", "Loading 2%"...) is not a Wine error:
            // it is written once, without the percentage, and its repeats are left out.
            if let progress = withoutPercentages(line) {
                let key = normalized(Substring(progress))
                if progressShown.insert(key).inserted {
                    flushRun()
                    lastKey = nil
                    out.append(progress)
                }
                continue
            }
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
            let top = dropped.values.sorted { $0.count > $1.count }.prefix(15)
            result += "\n\n[iDeck] Lines left out after \(maximumRepeats) appearances (×count):\n"
            result += top.map { "(×\($0.count)) \($0.line)" }.joined(separator: "\n")
            if dropped.count > top.count { result += "\n… and \(dropped.count - top.count) more kinds of repeated lines" }
            result += "\n"
        }
        return result
    }

    /// The line without its percentages ("12%", "45.5 %"), or nil when it has none.
    static func withoutPercentages(_ line: Substring) -> String? {
        guard line.contains("%") else { return nil }
        var result = ""
        var digits = ""
        var found = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || (c == "." && !digits.isEmpty) {
                digits.append(c); i += 1; continue
            }
            if !digits.isEmpty {
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == "%", digits.last != "." {
                    found = true; digits = ""; i = j + 1; continue
                }
                result += digits; digits = ""
            }
            result.append(c); i += 1
        }
        result += digits
        guard found else { return nil }
        let collapsed = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var text = collapsed
        while let last = text.last, " :-(,".contains(last) { text.removeLast() }
        return text
    }

    /// The line with timestamps, hex addresses, numbers and thread ids replaced, so
    /// repeats that differ only in them share a key.
    static func normalized(_ line: Substring) -> String {
        var key = ""
        key.reserveCapacity(line.count)
        var word = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            key += isNumberLike(word) ? "#" : word
            word = ""
        }
        for c in line.unicodeScalars {
            if ("0"..."9").contains(c) || ("a"..."z").contains(c) || ("A"..."Z").contains(c) {
                word.unicodeScalars.append(c)
            } else {
                flushWord()
                key.unicodeScalars.append(c)
            }
        }
        flushWord()
        return key
    }

    /// A word that is a number: decimal, 0x-hex, a hex address or id without 0x
    /// ("7ffe1a2b", "c000001d", "40010006"), or digits with a unit ("12ms", "4096KB").
    /// Words such as "fixme" or "deadline" stay as they are.
    static func isNumberLike(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard let first = scalars.first else { return false }
        func isHex(_ c: Unicode.Scalar) -> Bool {
            ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
        }
        if scalars.count > 2, first == "0", scalars[1] == "x" || scalars[1] == "X" {
            return scalars.dropFirst(2).allSatisfy(isHex)
        }
        if ("0"..."9").contains(first) { return true }
        // Letters first: hex only when long and with a digit, so words are kept.
        return scalars.count >= 6 && scalars.allSatisfy(isHex) && scalars.contains { ("0"..."9").contains($0) }
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
