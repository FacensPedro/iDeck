import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import CoreTransferable
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
            // Compacted byte by byte: no String of the whole log, no Character per line.
            let raw = try Data(contentsOf: source)
            try PrivacyRedactor.redact(LogCompactor.compactedData(raw)).write(to: destination, options: .atomic)
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
        try Data(PrivacyRedactor.redact(LogCompactor.compact(text)).utf8).write(to: destination, options: .atomic)
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

        var text = PrivacyRedactor.redact(String(decoding: data, as: UTF8.self))
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
        String(decoding: compactedData(Data(text.utf8)), as: UTF8.self)
    }

    /// `compact` on UTF-8 bytes. It works on the bytes of each line (no Character or
    /// String per line), so a Wine log of tens of MB is copied in a moment.
    static func compactedData(_ data: Data) -> Data {
        data.withUnsafeBytes { raw -> Data in
            let bytes = raw.bindMemory(to: UInt8.self)
            var out = [UInt8]()
            out.reserveCapacity(min(bytes.count, 1 << 20))
            var firstLine = true
            func emit<C: Collection>(_ line: C) where C.Element == UInt8 {
                if !firstLine { out.append(0x0A) }
                firstLine = false
                out.append(contentsOf: line)
            }
            var seen: [[UInt8]: Int] = [:]
            var dropped: [[UInt8]: (line: Range<Int>, count: Int)] = [:]
            var lastKey: [UInt8]?
            var run = 0
            func flushRun() {
                if run > 0 { emit(Array("↑ repeated \(run) more time\(run == 1 ? "" : "s")".utf8)) }
                run = 0
            }
            var progressShown = Set<[UInt8]>()
            var key = [UInt8]()
            key.reserveCapacity(256)
            var start = 0
            let count = bytes.count
            while start <= count {
                var end = start
                while end < count, bytes[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                let range = start..<end
                start = end + 1
                // A program's progress ("Loading 1%", "Loading 2%"...) is not a Wine error:
                // it is written once, without the percentage, and its repeats are left out.
                if line.contains(0x25),
                   let progress = withoutPercentages(Substring(String(decoding: line, as: UTF8.self))) {
                    let progressBytes = Array(progress.utf8)
                    normalizedKey(progressBytes, into: &key)
                    if progressShown.insert(key).inserted {
                        flushRun()
                        lastKey = nil
                        emit(progressBytes)
                    }
                    continue
                }
                normalizedKey(line, into: &key)
                if key == lastKey { run += 1; continue }
                flushRun()
                lastKey = key
                let times = (seen[key] ?? 0) + 1
                seen[key] = times
                if times <= maximumRepeats {
                    emit(line)
                } else {
                    dropped[key, default: (range, 0)].count += 1
                }
            }
            flushRun()
            if !dropped.isEmpty {
                let top = dropped.values.sorted { $0.count > $1.count }.prefix(15)
                var summary = "\n\n[iDeck] Lines left out after \(maximumRepeats) appearances (×count):\n"
                summary += top.map { "(×\($0.count)) " + String(decoding: UnsafeBufferPointer(rebasing: bytes[$0.line]), as: UTF8.self) }
                    .joined(separator: "\n")
                if dropped.count > top.count { summary += "\n… and \(dropped.count - top.count) more kinds of repeated lines" }
                summary += "\n"
                out.append(contentsOf: summary.utf8)
            }
            return Data(out)
        }
    }

    /// The line with timestamps, hex addresses, numbers and thread ids replaced by "#",
    /// so repeats that differ only in them share a key; written into `key` (reused).
    static func normalizedKey<C: Collection>(_ line: C, into key: inout [UInt8]) where C.Element == UInt8 {
        key.removeAll(keepingCapacity: true)
        var wordStart = -1
        func flushWord() {
            guard wordStart >= 0 else { return }
            if isNumberLike(key[wordStart...]) {
                key.removeSubrange(wordStart...)
                key.append(0x23) // "#"
            }
            wordStart = -1
        }
        for c in line {
            if (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) {
                if wordStart < 0 { wordStart = key.count }
                key.append(c)
            } else {
                flushWord()
                key.append(c)
            }
        }
        flushWord()
    }

    /// `isNumberLike` on an ASCII word's bytes (same rules).
    static func isNumberLike(_ word: ArraySlice<UInt8>) -> Bool {
        guard let first = word.first else { return false }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) }
        if word.count > 2, first == 0x30, word[word.startIndex + 1] == 0x78 || word[word.startIndex + 1] == 0x58 {
            return word.dropFirst(2).allSatisfy(isHex)
        }
        if isDigit(first) { return true }
        return word.count >= 6 && word.allSatisfy(isHex) && word.contains(where: isDigit)
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
        try writeCompressed(data: Data(text.utf8), to: url)
    }

    static func writeCompressed(data text: Data, to url: URL) throws {
        let data = compactedData(text) as NSData
        try data.compressed(using: .lzfse).write(to: url, options: .atomic)
    }

    static func readCompressed(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) as NSData,
              let plain = try? data.decompressed(using: .lzfse) else { return nil }
        return String(decoding: plain as Data, as: UTF8.self)
    }
}

/// Removes what identifies the user from iDeck's and Wine's logs before they are
/// written, copied or shared: passwords, tokens, account names, e-mail addresses,
/// IP addresses and the Windows user folder's name.
enum PrivacyRedactor {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var identifiers: Set<String> = []

    /// An account name or display name iDeck learned at sign-in (Steam, EA, Epic, GOG):
    /// it is removed wherever it appears in a log.
    static func register(_ identifier: String?) {
        guard let value = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 3 else { return }
        lock.lock(); identifiers.insert(value); lock.unlock()
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// (pattern, template): applied in order.
    private static let rules: [(NSRegularExpression, String)] = [
        // key=value and "key": "value" pairs that hold a secret or an account.
        (regex(#"(\b(?:password|passwd|pwd|pass|secret|token|access_token|refresh_token|id_token|auth_?code|authcode|code_verifier|session_?id|sessionkey|ticket|cookie|apikey|api_key|client_secret|license_?key|username|user_?name|user|account_?name|accountname|account|account_?id|steam_?id|login|email|persona_?name|display_?name|nickname)\\?"?\s*[:=]\s*\\?"?)[^\s"&,;}\]\\]+"#), "$1<redacted>"),
        (regex(#"(authorization\s*:\s*(?:bearer|basic|token)?\s*)[^\s"]+"#), "$1<redacted>"),
        (regex(#"(set-cookie|cookie)(\s*:\s*)[^\r\n]+"#), "$1$2<redacted>"),
        (regex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#), "<email>"),
        // IPv4 (loopback and 0.0.0.0 stay: they say nothing about the user).
        (regex(#"\b(?!127\.)(?!0\.0\.0\.0\b)(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#), "<ip>"),
        // IPv6 (at least three groups, so times such as 12:34:56 are kept).
        (regex(#"\b(?:[0-9A-F]{1,4}:){3,7}[0-9A-F]{1,4}\b|\b(?:[0-9A-F]{1,4}:){1,6}:(?:[0-9A-F]{1,4}:?){1,6}\b"#), "<ip>"),
        // C:\users\<name>\ and drive_c/users/<name>/: the Windows profile's name.
        (regex(#"((?:[A-Z]:\\+|drive_c/)users[\\/]+)(?!public\b|default\b|steamuser\b|all users\b)[^\\/\s"']+"#), "$1<user>"),
        // Long tokens (JWTs, OAuth codes, hex keys).
        (regex(#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#), "<redacted>"),
    ]

    /// Words that must appear in the text for a rule to run (lowercased): a rule
    /// whose words are all absent is skipped, so a long Wine log is not scanned by
    /// every expression.
    private static let ruleHints: [[String]] = [
        ["pass", "pwd", "secret", "token", "auth", "code", "session", "ticket", "cookie", "key",
         "user", "account", "login", "mail", "steam", "persona", "name"],
        ["authorization"],
        ["cookie"],
        ["@"],
        ["."],
        [":"],
        ["users"],
        ["eyj"],
    ]

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // One NSMutableString for every rule: no UTF-16 copy of the log per rule.
        let result = NSMutableString(string: text)
        let lowered = text.lowercased()
        for (index, (expression, template)) in rules.enumerated() {
            guard ruleHints[index].contains(where: { lowered.contains($0) }) else { continue }
            expression.replaceMatches(in: result, range: NSRange(location: 0, length: result.length),
                                      withTemplate: template)
        }
        lock.lock(); let known = identifiers; lock.unlock()
        for identifier in known.sorted(by: { $0.count > $1.count }) where lowered.contains(identifier.lowercased()) {
            result.replaceOccurrences(of: identifier, with: "<account>", options: .caseInsensitive,
                                      range: NSRange(location: 0, length: result.length))
        }
        return result as String
    }

    static func redact(_ data: Data) -> Data {
        Data(redact(String(decoding: data, as: UTF8.self)).utf8)
    }

    /// A redacted copy of a log file, for sharing.
    static func redactedCopy(of source: URL, name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = destination.appendingPathComponent(name + ".txt")
        try redact(LogCompactor.compactedData(try Data(contentsOf: source))).write(to: file, options: .atomic)
        return file
    }
}

#if canImport(UIKit)
/// A log shared through ShareLink: the file handed over is a redacted copy.
struct RedactedLogFile: Transferable {
    let url: URL
    var name = "Wine-log"

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { log in
            SentTransferredFile(try PrivacyRedactor.redactedCopy(of: log.url, name: log.name))
        }
    }
}
#endif
