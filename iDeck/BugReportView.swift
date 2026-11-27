import SwiftUI
import UIKit
import Darwin

/// iDeck's own persistent log (Documents/iDeck-app-log.txt). Everything else
/// only reaches stdout, which nobody can read after the fact; this file is
/// what the Bugs & logs screen scans. Lines never contain credentials: the
/// callers (SteamLog, status updates) already redact them.
enum AppLog {
    static let maximumBytes: UInt64 = 512 * 1024
    private static let queue = DispatchQueue(label: "ideck.app-log", qos: .utility)
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // The device's own clock and time zone (ISO 8601 defaults to UTC, "Z"):
        // log times match the time shown on the iPad.
        formatter.timeZone = .current
        return formatter
    }()

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iDeck-app-log.txt", isDirectory: false)
    }

    /// The previous file, kept once when the current one reaches `maximumBytes`.
    static var rotatedURL: URL? {
        fileURL?.deletingPathExtension().appendingPathExtension("1.txt")
    }

    /// Messages already written (numbers, addresses and times removed), and the
    /// repeats of the last one left out in a row; touched only on `queue`.
    nonisolated(unsafe) private static var written = Set<String>()
    nonisolated(unsafe) private static var lastKey: String?
    nonisolated(unsafe) private static var run = 0
    private static let maximumKeys = 4000

    /// Writes a message once: a repeat (same text apart from numbers, addresses
    /// or ids) is left out, and a run of repeats in a row ends with one
    /// "repeated N more times" line, so the log stays short.
    static func record(_ message: String) {
        let text = PrivacyRedactor.redact(message.replacingOccurrences(of: "\n", with: " ⏎ "))
        let date = Date()
        queue.async {
            let key = LogIssueScanner.normalized(text.lowercased())
            if key == lastKey { run += 1; return }
            var line = ""
            if run > 0 {
                line += stamp.string(from: date) + " ↑ repeated \(run) more time\(run == 1 ? "" : "s")\n"
            }
            run = 0
            lastKey = key
            if written.count >= maximumKeys { written.removeAll(keepingCapacity: true) }
            if written.insert(key).inserted {
                line += stamp.string(from: date) + " " + text + "\n"
            }
            if !line.isEmpty { append(line) }
        }
    }

    /// Appends to the file, rotating it at `maximumBytes`; runs on `queue`.
    private static func append(_ line: String) {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
               size + UInt64(data.count) > maximumBytes, let rotated = rotatedURL {
                try? manager.removeItem(at: rotated)
                try? manager.moveItem(at: url, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
    }

    /// Deletes the log now (waits for pending writes first), so a scan right
    /// after it no longer finds the old lines.
    static func clear() {
        queue.sync {
            written.removeAll()
            lastKey = nil
            run = 0
            for url in [fileURL, rotatedURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// One problem found in a log: repeated lines that differ only in numbers,
/// addresses or thread ids are folded into a single entry with a count.
struct LogIssue: Identifiable, Hashable {
    enum Source: String { case app = "iDeck", wine = "Wine", jit = "JIT" }
    let id: String
    let source: Source
    let severity: Int          // 2 = error/crash, 1 = failure/warning
    let line: String           // the most recent occurrence
    var count: Int

    var copyText: String { "[\(source.rawValue)] " + (count > 1 ? "(×\(count)) " : "") + line }
}

enum LogIssueScanner {
    /// Patterns are matched case-insensitively against each line.
    private static let errors = [
        "error", "err:", "fatal", "crash", "exception", "panic", "abort", "pressure critical",
        "c0000005", "c000001d", "c0000135", "status_access_violation", "unhandled",
        "checksum mismatch", "hash verification failed", "illegal instruction",
    ]
    private static let failures = [
        "failed", "failure", "cannot", "could not", "unable to", "timed out", "timeout",
        "denied", "warning", "warn:", "missing", "stale", "mprotect", "invalid",
        "wineserver timeout", "usbmux timeout", "no drawable available",
    ]
    /// Wine debug channels that print "err:" for harmless probing, and Madeira's
    /// informational lines that only look like failures: commit-zero's success
    /// counters ("stale=0/0"), ml990's address-space cap, the wineserver's infinite
    /// master-socket timeout and the iOS environment listing.
    /// Madeira's own tracing also prints through "err:" without being a failure: thread
    /// and process exits with status 0, RPC argument dumps, directory-cache counters,
    /// detach probes, the NtProtect sync scan, std-handle checks at exit and window traces.
    private static let noise = ["fixme:", "err:ole:", "err:winediag:", "[commit-zero]", "guest ok",
                                "ml990:", "master_socket_timeout", "[ios env]",
                                "[thr-exit]", "[ndr-param]", "[ndr-shift]", "[dircache]", "[detach-probe]",
                                "ntprotect-sync", "ntprotectvirtualmemory(orig=", "[std-handles]", "trace:win:",
                                "exit_process: raw_status=0x0", "process_exiting=1, forcing exit_process(0)",
                                "exit_code=0x0)", "msctfp.dll"]
    /// Counters that report no problem at all ("launch-client-error=0").
    private static let zeroCount = try! NSRegularExpression(pattern: #"\b(error|errors|failed|failures|missing)\s*[=:]\s*0\b"#)
    /// Informational lines a report keeps although they name no failure.
    private static let diagnostics = ["[ideck-fault]", "[dock-installers]", "[steam-redist]", "[touch] tap", "[memory] session", "[ea-service]", "[ea-license]", "[ea-activation-log]", "[jit-handoff]", "[download]", "[ea-download]"]
    /// Lines from iDeck's Steam client, downloads and Madeira Dock.
    private static let steamTags = ["[steam", "[dock", "steam client", "steam's", "madeira dock", "steamworks", "steam_api"]

    /// `steamSession` false leaves Steam-only lines out: they belong to an
    /// earlier Steam run, not to the game (GOG, Epic, any .exe) that failed.
    static func scan(_ text: String, source: LogIssue.Source, steamSession: Bool = true, limit: Int = 600) -> [LogIssue] {
        var found: [String: LogIssue] = [:]
        var order: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let original = raw.trimmingCharacters(in: .whitespaces)
            guard !original.isEmpty else { continue }
            // Native Wine output may include very long diagnostic lines.
            // Preserve both ends instead of silently discarding the problem.
            var line = original.count <= 2000
                ? String(original)
                : String(original.prefix(1200)) + " … " + String(original.suffix(750))
            var lower = line.lowercased()
            if noise.contains(where: lower.contains) { continue }
            // Wine's generic advice ("enable coredumps (ulimit -c unlimited)") does
            // not apply on iPadOS: point at the iOS crash diagnostics instead.
            if lower.contains("wineserver crashed") {
                line = "wineserver stopped unexpectedly. Wine's \"ulimit -c\" advice does not apply on iPadOS: see the [ios-crash] lines (MetricKit) and Settings › Privacy & Security › Analytics Data › iDeck."
                lower = line.lowercased()
            }
            if !steamSession, steamTags.contains(where: lower.contains) { continue }
            // Counts such as missing=0, errors=0 or failed=0 are normal
            // success telemetry. Remove only those zero-valued terms so a
            // real failure elsewhere in the same line remains visible.
            let range = NSRange(lower.startIndex..., in: lower)
            let actionable = zeroCount.stringByReplacingMatches(in: lower, range: range, withTemplate: "")
                // "invalidate" (a window or cache being redrawn) is not "invalid".
                .replacingOccurrences(of: "invalidat", with: "")
            // [touch] lines are diagnostics, not failures: kept so a report shows
            // where a tap that did nothing was sent. The EA service's and licence's
            // lines say whether a game talked to the local EA service and what its
            // licence was asked for.
            let severity = errors.contains(where: actionable.contains) ? 2
                : (failures.contains(where: actionable.contains) || diagnostics.contains(where: lower.contains)) ? 1 : 0
            guard severity > 0 else { continue }
            // JIT problems get their own group, whichever log they came from.
            let lineSource: LogIssue.Source = (lower.contains("jit ") || lower.contains("[jit") || lower.contains("jit:")) ? .jit : source
            let key = lineSource.rawValue + ":" + normalized(lower)
            if var issue = found[key] {
                issue.count += 1
                found[key] = LogIssue(id: key, source: lineSource, severity: max(issue.severity, severity),
                                      line: String(line), count: issue.count)
            } else {
                found[key] = LogIssue(id: key, source: lineSource, severity: severity, line: String(line), count: 1)
                order.append(key)
            }
        }
        // Newest distinct problems first, errors before failures.
        return order.reversed().compactMap { found[$0] }
            .sorted { $0.severity > $1.severity }
            .prefix(limit).map { $0 }
    }

    /// Strips timestamps, hex values, numbers and thread prefixes so repeats fold together.
    static func normalized(_ line: String) -> String {
        var text = line
        // A Wine thread id ("00bc:") is a prefix like the time: the same message from
        // two threads is one problem.
        for pattern in [#"^\S*\d{4}-\d\d-\d\dT\S+\s*"#, #"^[0-9a-f]{4}:"#, #"0x[0-9a-f]+"#, #"\b[0-9a-f]{6,}\b"#, #"\d+"#] {
            text = text.replacingOccurrences(of: pattern, with: "#", options: .regularExpression)
        }
        return text
    }
}

/// What an EA game's activation library did in the last Wine log: the licence files it
/// opened, the WMI queries its machine hash is built from, the volume serial and SMBIOS
/// identity ntdll answered with, the display adapter registered, and how
/// ActivationUI.exe was started. A game that refuses its licence says nothing itself;
/// these lines are what it read before it decided.
enum EAActivationTrace {
    static let limit = 140

    /// Whether a lower-cased log line belongs in the trace.
    static func matches(_ lower: String) -> Bool {
        for word in [".dlf", "wbemprox", "[vgpu]", "ios volume serial", "ios smbios", "\\wbem:"] where lower.contains(word) { return true }
        return lower.contains("activation") && (lower.contains("trace:process") || lower.contains("loaddll"))
    }

    static func capped(_ line: String) -> String {
        line.count <= 400 ? line : String(line.prefix(400)) + " …"
    }

    /// A line that may carry an account's token or address (a command line, EA's own
    /// logs): long tokens and e-mail addresses removed, capped in length.
    static func sanitized(_ line: String) -> String {
        var text = line
        for (pattern, replacement) in [(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
                                       (#"[A-Za-z0-9+/=_-]{24,}"#, "<redacted>")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return capped(text)
    }

    /// What makes two trace lines the same: pointers and handles removed, numbers kept
    /// (a licence file is named by its content id, which is all digits).
    static func key(_ lower: String) -> String {
        var text = lower
        for pattern in [#"0x[0-9a-f]+"#, #"\b[0-9a-f]{12,}\b"#, #"\b(?=[0-9a-f]*[a-f])[0-9a-f]{8}\b"#] {
            text = text.replacingOccurrences(of: pattern, with: "#", options: .regularExpression)
        }
        return text
    }

    /// The distinct matching lines of a log, oldest first, read in pieces from its
    /// newest `maximumBytes`.
    static func extract(from url: URL, maximumBytes: UInt64 = 32 * 1024 * 1024) -> [String] {
        lines(of: url, maximumBytes: maximumBytes, limit: limit, matches: matches) { lower, line in
            // Only a command line can carry a token; WMI queries and file names are kept whole.
            lower.contains("trace:process") ? sanitized(line) : capped(line)
        }
    }

    /// The distinct lines of a log that `matches` accepts, oldest first, each passed
    /// through `shown`, read in pieces from the log's newest `maximumBytes`.
    static func lines(of url: URL, maximumBytes: UInt64 = 32 * 1024 * 1024, limit: Int,
                      matches: (String) -> Bool, shown: (String, String) -> String) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        guard (try? handle.seek(toOffset: size > maximumBytes ? size - maximumBytes : 0)) != nil else { return [] }
        var pending = Data()
        var seen = Set<String>()
        var lines: [String] = []
        while lines.count < limit, let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            guard let cut = pending.lastIndex(of: UInt8(ascii: "\n")) else {
                // No line break in 8 MiB: not a text log worth keeping in memory.
                if pending.count > 8 * 1024 * 1024 { pending.removeAll() }
                continue
            }
            let text = String(decoding: pending[pending.startIndex..<cut], as: UTF8.self)
            pending = Data(pending[pending.index(after: cut)...])
            for raw in text.split(separator: "\n") where lines.count < limit {
                let lower = raw.lowercased()
                guard matches(lower), seen.insert(key(lower)).inserted else { continue }
                lines.append(shown(lower, raw.trimmingCharacters(in: .whitespaces)))
            }
        }
        return lines
    }
}

/// The programs the last Windows session started, from Wine's process trace
/// (CreateProcess's "app ... cmdline ..." line): what a game runs at its first start
/// (Visual C++, DirectX, PhysX, .NET, its own launcher or installer), marked
/// "installer" when the name says so.
enum SessionProgramsTrace {
    static let limit = 60
    static let installerWords = ["setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx", "physx",
                                 "dotnet", "ndp", "netfx", "msiexec", ".msi", "oalinst", "xnafx", "ue4prereq", "prereq",
                                 "easyanticheat", "uplay", "ubisoftconnect", "eadm", "touchup"]

    static func matches(_ lower: String) -> Bool { lower.contains("trace:process") && lower.contains(" cmdline ") }

    /// "installer: <command line>" or "program: <command line>", tokens removed.
    static func shown(_ lower: String, _ line: String) -> String {
        var command = line
        if let range = line.range(of: " cmdline ") { command = String(line[range.upperBound...]) }
        command = command.replacingOccurrences(of: #"^L""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #""$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\\\", with: "\\")
        let commandLower = command.lowercased()
        let kind = installerWords.contains(where: commandLower.contains) ? "installer" : "program"
        return kind + ": " + EAActivationTrace.sanitized(command)
    }

    static func extract(from url: URL) -> [String] {
        EAActivationTrace.lines(of: url, limit: limit, matches: matches, shown: shown)
    }
}

/// Where the last Windows exception in a Wine log happened: its code and address, and
/// the module loaded nearest below that address (Wine's loaddll trace names each
/// module with its base). Module sizes are not in the log, so the module is the
/// nearest one, and an address far past it is reported as outside any module.
enum CrashLocation {
    struct Module { var base: UInt64; var name: String }

    private static let loaded = try! NSRegularExpression(pattern: #"Loaded L"([^"]+)" at ([0-9A-Fa-f]{6,16})"#)
    private static let peAddress = try! NSRegularExpression(pattern: #"PE ExceptionAddress 0x([0-9a-fA-F]+)"#)
    private static let exception = try! NSRegularExpression(pattern: #"Exception: Code: ([0-9A-Fa-f]+) Address: ([0-9A-Fa-f]+)"#)
    private static let raise = try! NSRegularExpression(pattern: #"raise tid=\w+ code=([0-9a-fA-F]+) .*?addr=0x([0-9a-fA-F]+)"#)

    private static func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }

    /// The module holding `address`: the one with the highest base at or below it,
    /// unless the address is more than 256 MB past that base.
    static func module(for address: UInt64, in modules: [Module]) -> (Module, UInt64)? {
        guard let best = modules.filter({ $0.base <= address }).max(by: { $0.base < $1.base }) else { return nil }
        let offset = address - best.base
        return offset < 256 << 20 ? (best, offset) : nil
    }

    /// One line for a report, or nil when the log names no exception.
    static func describe(code: String?, address: UInt64, modules: [Module]) -> String {
        let where_ = module(for: address, in: modules).map { "\($0.0.name)+0x\(String($0.1, radix: 16))" }
            ?? "outside every module the log names (runtime or JIT code)"
        return (code.map { "exception 0x\($0.lowercased()) " } ?? "") + "at 0x\(String(address, radix: 16)) in " + where_
    }

    static func find(in url: URL, maximumBytes: UInt64 = 32 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > maximumBytes ? size - maximumBytes : 0)) != nil else { return nil }
        var modules: [Module] = []
        var lastCode: String?, lastAddress: UInt64?
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            guard let cut = pending.lastIndex(of: UInt8(ascii: "\n")) else {
                if pending.count > 8 * 1024 * 1024 { pending.removeAll() }
                continue
            }
            let text = String(decoding: pending[pending.startIndex..<cut], as: UTF8.self)
            pending = Data(pending[pending.index(after: cut)...])
            for raw in text.split(separator: "\n") {
                let line = String(raw)
                if line.contains("Loaded L\""), let g = groups(loaded, line), g.count == 2, let base = UInt64(g[1], radix: 16) {
                    let name = g[0].replacingOccurrences(of: "\\\\", with: "\\").split(separator: "\\").last.map(String.init) ?? g[0]
                    modules.append(Module(base: base, name: name))
                } else if line.contains("PE ExceptionAddress"), let g = groups(peAddress, line), let address = UInt64(g[0], radix: 16) {
                    lastAddress = address
                } else if line.contains("Exception: Code:"), let g = groups(exception, line), g.count == 2,
                          let address = UInt64(g[1], radix: 16) {
                    lastCode = g[0]; lastAddress = address
                } else if line.contains("raise tid="), let g = groups(raise, line), g.count == 2, let address = UInt64(g[1], radix: 16) {
                    lastCode = g[0]; lastAddress = address
                }
            }
        }
        guard let lastAddress else { return nil }
        return describe(code: lastCode, address: lastAddress, modules: modules)
    }
}

/// What the prefix itself holds about an EA game's activation: the licence files on
/// disk and the newest lines of the logs EA's own programs (ActivationUI.exe) wrote in
/// C:\ProgramData\Origin\Logs.
enum EAPrefixEvidence {
    static let logFolder = ["ProgramData", "Origin", "Logs"]

    /// A folder below `drive` by its Windows names, whatever their case on disk.
    static func folder(drive: URL, components: [String]) -> URL? {
        var url = drive
        for name in components {
            guard let next = EALicense.child(of: url, named: name) else { return nil }
            url = next
        }
        return url
    }

    /// The licence folder's files with their sizes.
    static func licenceFiles(drive: URL) -> String {
        let licences = EALicense.folder(drive: drive)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: licences.path), !names.isEmpty else { return "none" }
        return names.sorted().prefix(12).map { name -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: licences.appendingPathComponent(name).path)
            guard let size = (attributes?[.size] as? NSNumber)?.intValue else { return name }
            return "\(name) \(size) B"
        }.joined(separator: ", ")
    }

    /// A log's text without markup: tags and the common entities removed.
    static func plainText(_ data: Data) -> String {
        // EA's logs are UTF-8 or UTF-16 (a zero in the second byte).
        // EA's activation logs are UTF-16 with a byte-order mark (FF FE), so the second
        // byte is not zero: count zero bytes instead (2.15.0 printed "L i c e n s e").
        var body = data
        if body.count >= 2, body[body.startIndex] == 0xFF, body[body.startIndex + 1] == 0xFE { body = body.dropFirst(2) }
        let sample = body.prefix(4096)
        let zeros = sample.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        let utf16 = sample.count >= 2 && zeros * 4 >= sample.count
        if utf16 && body.count % 2 == 1 { body = body.dropLast() }
        var text = utf16 ? (String(data: Data(body), encoding: .utf16LittleEndian) ?? "") : String(decoding: body, as: UTF8.self)
        text = text.replacingOccurrences(of: #"<(br|/tr|/p|/div|/li)[^>]{0,80}>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]{0,300}>"#, with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// The newest lines EA's activation window wrote, for iDeck's own log after a session in
    /// which the game started ActivationUI.exe: they say why the licence was refused.
    /// Addresses, e-mails, long tokens and the account names in `hidden` are removed.
    static func activationReason(drive: URL, hidden: [String], lines count: Int = 60) -> [String] {
        // EA's log is an HTML page: keep its file line and the numbered rows only,
        // not the page's style sheet (2.15.1 showed 40 lines of CSS).
        // Rows whose cells end up on lines of their own (the reason a licence was refused
        // follows the row number) are kept too: only style rules are dropped. 3.0 showed
        // rows 1 and 2 only, the file's oldest, whatever the activation window wrote after.
        originLogs(drive: drive, files: 1, linesPerFile: count).filter { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("  ") else { return true }
            if text.first?.isNumber == true { return true }
            let style = text.contains("{") || text.contains("}")
                || text.range(of: #"^[A-Za-z-]+\s*:\s*[^ ]+;$"#, options: .regularExpression) != nil
            return !style
        }.map { line in
            var text = line.replacingOccurrences(of: #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, with: "<ip>", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){4,7}\b"#, with: "<ip>", options: .regularExpression)
            for name in hidden where name.count >= 3 {
                text = text.replacingOccurrences(of: name, with: "<account>", options: .caseInsensitive)
            }
            return text
        }
    }

    /// The newest files of EA's log folder: name, size and time, then each one's last lines.
    static func originLogs(drive: URL, files: Int = 4, linesPerFile: Int = 25) -> [String] {
        guard let logs = folder(drive: drive, components: logFolder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: logs.path) else { return [] }
        let entries = names.compactMap { name -> (name: String, size: Int, date: Date)? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: logs.appendingPathComponent(name).path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { return nil }
            return (name, (attributes?[.size] as? NSNumber)?.intValue ?? 0, attributes?[.modificationDate] as? Date ?? .distantPast)
        }.sorted { $0.date > $1.date }
        var lines: [String] = []
        for entry in entries.prefix(files) {
            lines.append("\(entry.name), \(entry.size) B, \(ISOStamp.localString(entry.date))")
            // The reader page EA copies next to its logs is not a log.
            guard entry.size > 0, !entry.name.lowercased().hasSuffix("reader.html") else { continue }
            guard let handle = try? FileHandle(forReadingFrom: logs.appendingPathComponent(entry.name)) else { continue }
            defer { try? handle.close() }
            let tail: UInt64 = 64 * 1024
            _ = try? handle.seek(toOffset: UInt64(entry.size) > tail ? (UInt64(entry.size) - tail) & ~1 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            let text = plainText(data).split(whereSeparator: \.isNewline)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
            lines += text.suffix(linesPerFile).map { "  " + EAActivationTrace.sanitized($0) }
        }
        return lines
    }
}

/// DLLs and functions the last Windows session could not find, from Wine's own messages:
/// a missing import library, a library that failed to load, an import with no
/// implementation, an unimplemented function that was called, and a DLL looked up in
/// system32/syswow64 (the last place Windows searches) that is not there.
enum MissingModuleScanner {
    private static let rules: [(pattern: String, format: ([Substring]) -> String)] = [
        (#"Library ([^ ]+) \(which is needed by L?"?([^)"]+)"?\) not found"#, { "\($0[0]) (needed by \(name($0[1])))" }),
        (#"Loading library ([^ ]+) \(which is needed by L?"?([^)"]+)"?\) failed"#, { "\($0[0]) (failed to load, needed by \(name($0[1])))" }),
        (#"[Cc]ould not load L?"?([^ ",]+)"?, status"#, { "\(name($0[0])) (could not load)" }),
        (#"No implementation for ([^ .]+(?:\.dll)?)\.([^ ]+) imported from L?"?([^ ,"]+)"#, { "\($0[0]).\($0[1]) (function, imported by \(name($0[2])))" }),
        (#"[Uu]nimplemented function ([^ .]+(?:\.dll)?)\.([^ ]+) called"#, { "\($0[0]).\($0[1]) (unimplemented function called)" }),
        (#"\\+windows\\+(?:system32|syswow64)\\+([^\\" ]+\.dll)"? not found"#, { "\($0[0]) (not in system32)" }),
    ]

    /// msctfp.dll is a private Text Services module Wine does not ship; programs probe for it.
    private static let optionalModules: Set<String> = ["steamservice.dll", "wow64cpu.dll", "msctfp.dll"]

    private static func name(_ path: Substring) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? path)
    }

    /// Every distinct finding in the log, in the order first seen.
    static func findings(in text: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        let compiled = rules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])).map { ($0, rule.format) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            for (regex, format) in compiled {
                guard let match = regex.firstMatch(in: string, range: range) else { continue }
                let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: string).map { string[$0] } }
                // DLLs Windows programs look for that are optional by design: Steam's
                // Windows service (steamservice.dll) does not run under Wine.
                if groups.first.map({ optionalModules.contains($0.lowercased()) }) == true { break }
                let finding = format(groups)
                if seen.insert(finding.lowercased()).inserted { result.append(finding) }
                break
            }
            if result.count >= 40 { break }
        }
        return result
    }

    /// The report line: the findings, or that the log has none (or no log exists).
    static func summary(_ text: String?) -> String {
        guard let text else { return "no Wine log to check" }
        let found = findings(in: text)
        return found.isEmpty ? "none reported in the Wine log" : found.joined(separator: "; ")
    }
}
