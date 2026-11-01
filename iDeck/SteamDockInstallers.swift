// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// MARK: - Steam install scripts

/// One "Run Process" entry of a game's Steam install script (installscript.vdf).
/// Valve's desktop client runs the entry's programs (typically runtime
/// redistributables) before a start unless the registry value `name` under `key`
/// is at least `value`, and records it once they have run (Steamworks, "Creating
/// and using InstallScripts").
struct SteamInstallRun: Equatable, Hashable, Sendable, Codable {
    enum Hive: String, Sendable, Codable { case machine, user }
    var name: String
    var hive: Hive
    var key: String      // under the hive, e.g. Software\Valve\Steam\Apps\<appid>
    var value: UInt32    // MinimumHasRunValue, else 1
}

/// One program of a "Run Process" entry, resolved to a Windows path.
struct SteamInstallProcess: Equatable, Sendable {
    var run: SteamInstallRun
    var executable: String      // C:\...
    var arguments: String
}

/// Reading install scripts and recording runs in the prefix's registry files.
/// The .reg files are only written while no session runs: the wineserver keeps
/// the registry in memory and writes it back when it stops.
enum SteamInstallScripts {
    static let maxScriptBytes = 1 << 20

    /// "HKEY_LOCAL_MACHINE\Software\..." -> (.machine, "Software\...").
    static func hive(_ path: String) -> (SteamInstallRun.Hive, String)? {
        let parts = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let first = parts.first?.uppercased() else { return nil }
        let rest = parts.dropFirst().joined(separator: "\\")
        switch first {
        case "HKEY_LOCAL_MACHINE", "HKLM": return (.machine, rest)
        case "HKEY_CURRENT_USER", "HKCU": return (.user, rest)
        default: return nil
        }
    }

    /// The keys a run is recorded under. A 32-bit reader sees HKLM\Software through
    /// Wow6432Node in a 64-bit prefix; the plain key covers a 64-bit reader.
    static func keys(_ run: SteamInstallRun) -> [String] {
        let lower = run.key.lowercased()
        guard run.hive == .machine, lower.hasPrefix("software\\"), !lower.hasPrefix("software\\wow6432node\\") else { return [run.key] }
        return [run.key, "Software\\Wow6432Node\\" + run.key.dropFirst("software\\".count)]
    }

    /// Install scripts: .vdf files with a "Run Process" section in `folder` and up to
    /// `depth` levels below it. Symbolic links are not followed.
    static func scripts(folder: URL, depth: Int = 1) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for item in items.sorted(by: { $0.path < $1.path }).prefix(500) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if depth > 0 { found += scripts(folder: item, depth: depth - 1) }
            } else if item.pathExtension.lowercased() == "vdf", (values.fileSize ?? .max) <= maxScriptBytes,
                      let contents = try? Data(contentsOf: item),
                      String(decoding: contents, as: UTF8.self).range(of: "run process", options: .caseInsensitive) != nil {
                found.append(item)
            }
        }
        return found
    }

    /// Where Valve's client records an entry that names no "HasRunKey": a DWORD named
    /// after the entry (lowercase, as its script parser keys it) under the app's own key.
    static func defaultRunKey(appID: Int) -> String { "Software\\Valve\\Steam\\Apps\\\(appID)" }

    /// The "HasRunKey" of an entry's fields, else (with a valid `appID` and a program to
    /// run) the per-app default key in full-path form.
    static func runKey(_ fields: [String: String], appID: Int?) -> String? {
        if let key = fields["hasrunkey"] { return key }
        guard let appID, appID > 0, appID < 1 << 31, fields.keys.contains(where: { $0.hasPrefix("process ") }) else { return nil }
        return "HKEY_LOCAL_MACHINE\\" + defaultRunKey(appID: appID)
    }

    /// Every "Run Process" entry with its fields (lowercased keys), read straight from the
    /// text. Scripts repeat the "Run Process" key, one section per installer, so a
    /// key-value reader that keeps the last copy of a repeated key would miss entries.
    static func entries(script: Data, appID: Int? = nil) -> [(SteamInstallRun, [String: String])] {
        var bytes = Array(script.prefix(maxScriptBytes))
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var position = 0
        func token() -> (text: String, quoted: Bool)? {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1; continue }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    while position < bytes.count, bytes[position] != 10 { position += 1 }
                    continue
                }
                break
            }
            guard position < bytes.count else { return nil }
            let first = bytes[position]; position += 1
            if first == 123 { return ("{", false) }
            if first == 125 { return ("}", false) }
            var value: [UInt8] = []
            if first == 34 {
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { break }
                    if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 { value.append(bytes[position]); position += 1 }
                    else { value.append(byte) }
                }
                return (String(decoding: value, as: UTF8.self), true)
            }
            value.append(first)
            while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 { value.append(bytes[position]); position += 1 }
            return (String(decoding: value, as: UTF8.self), true)
        }
        var result: [(SteamInstallRun, [String: String])] = []
        var path: [String] = []          // keys of the open sections, lowercased
        var pending: String?             // a key waiting for its value or section
        var fields: [String: String] = [:]
        var tokens = 0
        while let (text, quoted) = token() {
            tokens += 1
            if tokens > 200_000 || path.count > 32 { break }
            if !quoted && text == "{" {
                path.append(pending?.lowercased() ?? ""); pending = nil
                if path.count >= 2, path[path.count - 2] == "run process" { fields = [:] }
            } else if !quoted && text == "}" {
                // An entry section closes: path is [..., "run process", <entry>].
                if path.count >= 2, path[path.count - 2] == "run process", let name = path.last,
                   let key = runKey(fields, appID: appID), let (hive, sub) = hive(key), !sub.isEmpty {
                    let minimum = fields["minimumhasrunvalue"].flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                    let run = SteamInstallRun(name: name, hive: hive, key: sub, value: max(1, minimum))
                    if !result.contains(where: { $0.0 == run }) { result.append((run, fields)) }
                }
                if !path.isEmpty { path.removeLast() }
                pending = nil
            } else if let key = pending {
                if path.count >= 2, path[path.count - 2] == "run process" { fields[key.lowercased()] = text }
                pending = nil
            } else {
                pending = text
            }
        }
        return result
    }

    /// The .reg text with every run's value at least its minimum, and how many values changed.
    /// Wine's format: "[Key\\Sub] <time>" section headers, then "\"name\"=dword:00000001" lines.
    static func mark(_ runs: [SteamInstallRun], in text: String, now: Int) -> (text: String, changed: Int) {
        var lines = text.components(separatedBy: "\n")
        var changed = 0
        for run in runs {
            let valueName = "\"" + escape(run.name) + "\"="
            let valueLine = valueName + String(format: "dword:%08x", run.value)
            for key in keys(run) {
                let header = "[" + escape(key) + "]"
                if let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header.lowercased()) }) {
                    var end = start + 1
                    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                    if let index = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(valueName.lowercased()) }) {
                        if let current = dword(lines[index]), current >= run.value { continue }
                        lines[index] = valueLine
                    } else {
                        var at = end
                        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
                        lines.insert(valueLine, at: at)
                    }
                } else {
                    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
                    lines += ["", header + " \(now)", valueLine, ""]
                }
                changed += 1
            }
        }
        return (lines.joined(separator: "\n"), changed)
    }

    /// The .reg text without the runs' values (both views), and how many lines were removed.
    /// Only the value named after each entry goes; the key and its other values stay.
    static func unmark(_ runs: [SteamInstallRun], in text: String) -> (text: String, removed: Int) {
        var lines = text.components(separatedBy: "\n")
        var removed = 0
        for run in runs {
            let valueName = ("\"" + escape(run.name) + "\"=").lowercased()
            for key in keys(run) {
                let header = ("[" + escape(key) + "]").lowercased()
                guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
                var index = start + 1
                while index < lines.count, !lines[index].hasPrefix("[") {
                    if lines[index].lowercased().hasPrefix(valueName) { lines.remove(at: index); removed += 1 } else { index += 1 }
                }
            }
        }
        return (lines.joined(separator: "\n"), removed)
    }

    /// Records the runs in the prefix's system.reg and user.reg (a .madeira-bak copy is kept
    /// once). Returns the number of values written. Only while no session runs.
    @discardableResult
    static func mark(_ runs: [SteamInstallRun], prefix: URL) throws -> Int {
        let now = Int(Date().timeIntervalSince1970)
        return try rewrite(runs, prefix: prefix) { selected, text in
            let result = mark(selected, in: text, now: now)
            return (result.text, result.changed)
        }
    }

    /// Removes the runs' records from the prefix's system.reg and user.reg (the same
    /// .madeira-bak copy is kept once). Returns the number of values removed. Only while no
    /// session runs.
    @discardableResult
    static func unmark(_ runs: [SteamInstallRun], prefix: URL) throws -> Int {
        try rewrite(runs, prefix: prefix) { selected, text in
            let result = unmark(selected, in: text)
            return (result.text, result.removed)
        }
    }

    /// Applies `change` (new text, values changed) to each hive file that holds some of the
    /// runs and writes the files it changed. Returns the total of values changed.
    private static func rewrite(_ runs: [SteamInstallRun], prefix: URL,
                                _ change: ([SteamInstallRun], String) -> (String, Int)) throws -> Int {
        var total = 0
        for (hive, file) in [(SteamInstallRun.Hive.machine, "system.reg"), (.user, "user.reg")] {
            let selected = runs.filter { $0.hive == hive }
            guard !selected.isEmpty else { continue }
            let registry = prefix.appendingPathComponent(file)
            guard let contents = try? Data(contentsOf: registry), !contents.isEmpty else { continue }   // a prefix not seeded yet
            let (updated, changed) = change(selected, String(decoding: contents, as: UTF8.self))
            guard changed > 0 else { continue }
            let backup = registry.appendingPathExtension("madeira-bak")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: registry, to: backup) }
            try Data(updated.utf8).write(to: registry, options: .atomic)
            total += changed
        }
        return total
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func dword(_ line: String) -> UInt32? {
        guard let range = line.range(of: "=dword:", options: .caseInsensitive) else { return nil }
        return UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
    }
}

// MARK: - Planning, the batch and its results

/// What a Dock start does with one install-script program.
enum DockInstallStatus: String, Sendable {
    case done          // already recorded in the prefix's registry
    case missing       // the program is not on disk
    case unsupported   // this build cannot run it (see DockInstallers.runnable)
    case pending       // runs in the session before the host
    case limit         // over the per-start limit; runs at a later start
}

struct DockInstallPlanItem: Equatable, Sendable {
    var process: SteamInstallProcess
    var status: DockInstallStatus
    var reason: String? = nil     // why an unsupported program cannot run
}

/// The batch's service-manager step: `.start` runs the Dock executable with
/// `--start-services` before the first installer; `.off` only records "services off".
enum DockInstallServices: Equatable, Sendable {
    case off
    case start(String)
}

/// Valve's client runs a game's install scripts as part of its own launch tasks,
/// before the step Madeira Dock asks it for (LaunchApp), so on the Dock route
/// nothing runs them. Madeira does: every program not yet recorded runs once in
/// the Dock session before the host, from a batch that reports each exit status.
/// Every program is treated alike; nothing is decided by program name.
enum DockInstallScripts {
    /// The programs of one install script. `installDir` replaces %INSTALLDIR% (a Windows
    /// path). `appID` records entries without a "HasRunKey" under Steam's per-app key.
    static func processes(script: Data, installDir: String, appID: Int? = nil) -> [SteamInstallProcess] {
        var result: [SteamInstallProcess] = []
        for (run, fields) in SteamInstallScripts.entries(script: script, appID: appID) {
            let numbers = fields.keys.compactMap { key -> Int? in
                guard key.hasPrefix("process ") else { return nil }
                return Int(key.dropFirst("process ".count).trimmingCharacters(in: .whitespaces))
            }.sorted()
            for number in numbers.prefix(8) {
                guard let raw = fields["process \(number)"], !raw.isEmpty, raw.utf8.count <= 1024 else { continue }
                let exe = expand(raw, installDir: installDir)
                let lower = exe.lowercased()
                guard exe.count > 3, exe.hasPrefix("C:\\"), !exe.contains("%"), !exe.contains("\""),
                      !exe.contains(".."), lower.hasSuffix(".exe") || lower.hasSuffix(".msi") else { continue }
                let args = expand(fields["command \(number)"] ?? "", installDir: installDir, path: false)
                    .trimmingCharacters(in: .whitespaces)
                // No cmd.exe metacharacters: the arguments go into a batch line as they are.
                guard args.utf8.count <= 1024, !args.contains("\r"), !args.contains("\n"), !args.contains("&"),
                      !args.contains("|"), !args.contains(">"), !args.contains("<"), !args.contains("^"),
                      !args.contains("%") else { continue }
                let process = SteamInstallProcess(run: run, executable: exe, arguments: args)
                if !result.contains(process) { result.append(process) }
            }
        }
        return result
    }

    /// A program path gets Windows separators; an argument list keeps its "/switches".
    static func expand(_ text: String, installDir: String, path: Bool = true) -> String {
        var value = path ? text.replacingOccurrences(of: "/", with: "\\") : text
        value = value.replacingOccurrences(of: "%INSTALLDIR%", with: installDir, options: .caseInsensitive)
        if path { while value.contains("\\\\") { value = value.replacingOccurrences(of: "\\\\", with: "\\") } }
        return value
    }

    /// The value a run has in a Wine .reg text (highest of both views), nil when absent.
    static func recorded(_ run: SteamInstallRun, in text: String) -> UInt32? {
        let lines = text.components(separatedBy: "\n")
        let valueName = ("\"" + SteamInstallScripts.escape(run.name) + "\"=").lowercased()
        var best: UInt32?
        for key in SteamInstallScripts.keys(run) {
            let header = ("[" + SteamInstallScripts.escape(key) + "]").lowercased()
            guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
            var index = start + 1
            while index < lines.count, !lines[index].hasPrefix("[") {
                let line = lines[index].lowercased()
                if line.hasPrefix(valueName), let range = line.range(of: "=dword:"),
                   let value = UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) {
                    best = max(best ?? 0, value)
                }
                index += 1
            }
        }
        return best
    }

    /// Whether a run is recorded done (value at least its minimum in either view).
    static func marked(_ run: SteamInstallRun, in text: String) -> Bool {
        (recorded(run, in: text) ?? 0) >= run.value
    }

    /// Every program's fate at this start: done first, then whether the program exists,
    /// then whether this build can run it (`runnable` returns the reason it cannot);
    /// at most `limit` programs run per start.
    static func plan(_ found: [SteamInstallProcess], limit: Int = 8,
                     done: (SteamInstallRun) -> Bool, exists: (String) -> Bool,
                     runnable: (SteamInstallProcess) -> String? = { _ in nil }) -> [DockInstallPlanItem] {
        var result: [DockInstallPlanItem] = []
        var queued = 0
        for process in found {
            if done(process.run) { result.append(DockInstallPlanItem(process: process, status: .done)); continue }
            if !exists(process.executable) { result.append(DockInstallPlanItem(process: process, status: .missing)); continue }
            if let reason = runnable(process) {
                result.append(DockInstallPlanItem(process: process, status: .unsupported, reason: reason)); continue
            }
            if queued < limit { queued += 1; result.append(DockInstallPlanItem(process: process, status: .pending)) }
            else { result.append(DockInstallPlanItem(process: process, status: .limit)) }
        }
        return result
    }

    /// The Dock sheet's line about the plan, or nil when every program is already done.
    static func note(_ items: [DockInstallPlanItem]) -> String? {
        func names(_ status: DockInstallStatus) -> String {
            var seen: [String] = []
            for item in items where item.status == status {
                var text = label(item.process.run)
                if let reason = item.reason { text += " (" + reason + ")" }
                if !seen.contains(text) { seen.append(text) }
            }
            return seen.joined(separator: ", ")
        }
        guard items.contains(where: { $0.status != .done }) else { return nil }
        var parts: [String] = []
        if !names(.pending).isEmpty { parts.append("Runs first: " + names(.pending)) }
        if !names(.done).isEmpty { parts.append("Already done: " + names(.done)) }
        if !names(.missing).isEmpty { parts.append("Installer file missing: " + names(.missing)) }
        if !names(.unsupported).isEmpty { parts.append("Cannot run in this build: " + names(.unsupported)) }
        if !names(.limit).isEmpty { parts.append("Next start: " + names(.limit)) }
        return "One-time installs. " + parts.joined(separator: ". ") + "."
    }

    /// A program's label for logs, the batch and the sheet: the entry name, reduced to
    /// safe characters.
    static func label(_ run: SteamInstallRun) -> String {
        String(run.name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }.prefix(64))
    }

    /// The batch the Dock session runs before the host. Each program's start and exit
    /// status are appended to `resultFile` ("start <i> <label>", "exit <i> <status>"; every
    /// redirection follows a space, so a status digit is never read as a handle number).
    /// The batch records nothing in the registry itself: Madeira records the programs that
    /// exited with 0, 3010 or 1641 (installed, restart requested) at the next Dock start,
    /// when no session runs (DockInstallers.absorbResults).
    ///
    /// `services` first makes Wine's service manager reachable (`dockhost.exe
    /// --start-services` prints "services <outcome>" into the result file; "services failed"
    /// when it could not run) or records "services off".
    static func batch(_ processes: [SteamInstallProcess], resultFile: String, services: DockInstallServices) -> String {
        let result = " >>\"" + resultFile.replacingOccurrences(of: "\"", with: "") + "\""
        var lines = ["@echo off", "rem Madeira Dock: a game's one-time installs, before the host starts the game",
                     "echo begin \(processes.count)" + result.replacingOccurrences(of: " >>", with: " >")]
        switch services {
        case .off: lines.append("echo services off" + result)
        case .start(let executable):
            lines.append("\"" + executable.replacingOccurrences(of: "\"", with: "") + "\" --start-services" + result)
            lines.append("if not \"%ERRORLEVEL%\"==\"0\" echo services failed" + result)
        }
        for (offset, process) in processes.enumerated() {
            let index = offset + 1
            let quoted = "\"" + process.executable + "\""
            let command = process.executable.lowercased().hasSuffix(".msi")
                ? "C:\\windows\\system32\\msiexec.exe /i " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
                : "call " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
            let text = label(process.run)
            lines.append("echo [dock-installers] running \(index)/\(processes.count) " + text)
            lines.append("echo start \(index) " + text + result)
            lines.append(command)
            lines.append("echo exit \(index) %ERRORLEVEL%" + result)
        }
        lines.append("echo end" + result)
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A result file read back: programs in the batch, which started (index -> label),
    /// which exited (index -> status), the service step's outcome and whether the batch ended.
    struct Results: Equatable, Sendable {
        var total = 0
        var started: [Int: String] = [:]
        var exits: [Int: Int] = [:]
        var ended = false
        var services: String?
        var running: Int? { started.keys.filter { exits[$0] == nil }.max() }
        static func succeeded(_ status: Int) -> Bool { status == 0 || status == 3010 || status == 1641 }
    }

    static func results(_ text: String) -> Results {
        var results = Results()
        // cmd.exe writes CRLF; "\r\n" is one Character, so split on any newline Character.
        for raw in text.split(whereSeparator: { $0.isNewline }).prefix(200) {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            guard let verb = parts.first else { continue }
            switch verb {
            case "begin":
                results.total = parts.count > 1 ? min(Int(parts[1]) ?? 0, 64) : 0
            case "start":
                if parts.count > 1, let index = Int(parts[1]), (1...64).contains(index) {
                    results.started[index] = parts.count > 2 ? String(parts[2].prefix(64)) : ""
                }
            case "exit":
                if parts.count > 2, let index = Int(parts[1]), (1...64).contains(index),
                   let status = Int(parts[2].trimmingCharacters(in: .whitespaces)) { results.exits[index] = status }
            case "services":
                let word = parts.count > 1 ? String(parts[1].filter { $0.isLetter }.prefix(16)) : ""
                if !word.isEmpty { results.services = word }
            case "end":
                results.ended = true
            default:
                continue
            }
        }
        return results
    }
}

/// A request for one game's one-time installs, saved from the app at any time and applied
/// at that game's next Dock start, while no session runs (the registry is on disk then).


// iDeck adaptation: Steam's installscript.vdf prerequisites are executed in a
// separate Wine session to avoid exhausting the FEX executable pool while a
// Steam game loads. Only exit codes 0, 3010 and 1641 are recorded as done.
// A session must finish and the wineserver must stop before .reg files change.
enum IDeckSteamDockInstallers {
    struct Stage {
        let command: URL
        let appID: UInt32
        let count: Int
    }

    enum PreparationError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let explanation): return explanation
            }
        }
    }

    private static func stem(_ appID: UInt32) -> String {
        "ideck-dock-installers-\(appID)"
    }
    private static func resultFile(_ appID: UInt32, drive: URL) -> URL {
        drive.appendingPathComponent(stem(appID) + ".result")
    }
    private static func planFile(_ appID: UInt32, prefix: URL) -> URL {
        prefix.appendingPathComponent(stem(appID) + ".json")
    }
    private static func scriptFile(_ appID: UInt32, drive: URL) -> URL {
        drive.appendingPathComponent(stem(appID) + ".cmd")
    }

    /// All paths are confined to the Wine C: drive; no symlinks, UNC or
    /// cmd.exe metacharacters are allowed in an installer executable path.
    static func resolve(_ windowsPath: String, drive: URL) -> URL? {
        guard windowsPath.lowercased().hasPrefix("c:\\"),
              windowsPath.utf8.count < 1024,
              windowsPath.rangeOfCharacter(from: CharacterSet(charactersIn: "&|<>^%!\"\r\n")) == nil else { return nil }
        let parts = windowsPath.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") || $0.contains(":")
        }) else { return nil }
        let root = drive.resolvingSymlinksInPath().standardizedFileURL.path
        var current = drive
        for part in parts {
            let exact = current.appendingPathComponent(String(part))
            if FileManager.default.fileExists(atPath: exact.path) {
                current = exact
            } else {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                      let match = names.first(where: { $0.caseInsensitiveCompare(String(part)) == .orderedSame })
                else { return nil }
                current.appendPathComponent(match)
            }
            guard current.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else { return nil }
        }
        return current
    }

    static func find(appID: UInt32, game: DockGame, prefix: URL) -> [SteamInstallProcess] {
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let common = SteamInstallPaths.libraryRelative + "/common"
        let roots: [(URL, Int, String, Int?)] = [
            (drive.appendingPathComponent(common + "/" + game.installDir), 1, game.windowsInstallPath, Int(appID)),
            (drive.appendingPathComponent(common + "/Steamworks Shared/_CommonRedist"), 3,
             "C:\\" + (common + "/Steamworks Shared").replacingOccurrences(of: "/", with: "\\"), nil)
        ]
        let rootPath = drive.resolvingSymlinksInPath().standardizedFileURL.path
        var processes: [SteamInstallProcess] = []
        for (folder, depth, windowsFolder, owner) in roots {
            guard folder.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath + "/") else { continue }
            for file in SteamInstallScripts.scripts(folder: folder, depth: depth) {
                guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath + "/"),
                      let data = try? Data(contentsOf: file), data.count <= SteamInstallScripts.maxScriptBytes else { continue }
                for process in DockInstallScripts.processes(script: data, installDir: windowsFolder, appID: owner) {
                    if !processes.contains(process) { processes.append(process) }
                }
            }
        }
        return processes
    }

    private static func registry(_ prefix: URL, name: String) -> String {
        (try? String(contentsOf: prefix.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Consumes a previous install-only Wine session after the guest and the
    /// wineserver have exited. An interrupted batch never marks anything done.
    @discardableResult
    static func absorb(appID: UInt32, prefix: URL) throws -> String? {
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let planURL = planFile(appID, prefix: prefix)
        guard FileManager.default.fileExists(atPath: planURL.path) else { return nil }
        let saved = try Data(contentsOf: planURL)
        guard saved.count <= 65536,
              let runs = try? JSONDecoder().decode([SteamInstallRun].self, from: saved),
              (1...8).contains(runs.count) else {
            throw PreparationError.unavailable("Invalid Steam installer plan. Remove the damaged installer plan before retrying.")
        }
        let resultURL = resultFile(appID, drive: drive)
        guard let data = try? Data(contentsOf: resultURL), data.count <= 32768,
              let text = String(data: data, encoding: .utf8) else {
            return "Steam prerequisite installers did not produce a complete report. No install was marked done."
        }
        let receipt = DockInstallScripts.results(text)
        guard receipt.ended, receipt.total == runs.count else {
            return "Steam prerequisite installation was interrupted. No install was marked done."
        }
        var successful: [SteamInstallRun] = []
        for (offset, run) in runs.enumerated() {
            let index = offset + 1
            if receipt.started[index] == DockInstallScripts.label(run),
               let status = receipt.exits[index], DockInstallScripts.Results.succeeded(status) {
                successful.append(run)
            }
        }
        if !successful.isEmpty { try SteamInstallScripts.mark(successful, prefix: prefix) }
        try FileManager.default.removeItem(at: planURL)
        try? FileManager.default.removeItem(at: resultURL)
        try? FileManager.default.removeItem(at: scriptFile(appID, drive: drive))
        return "Steam prerequisites: \(successful.count) of \(runs.count) installed. "
             + (successful.count == runs.count ? "Start the game again." : "Review the failed installers before retrying.")
    }

    /// Create a single-install-session batch. Never impersonate Steam's
    /// licence check: the real Steam Dock still starts the game afterwards.
    static func stage(appID: UInt32, game: DockGame, prefix: URL) throws -> Stage? {
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let found = find(appID: appID, game: game, prefix: prefix)
        guard !found.isEmpty else { return nil }
        let machineRegistry = registry(prefix, name: "system.reg")
        let userRegistry = registry(prefix, name: "user.reg")
        let msiexec = resolve("C:\\windows\\system32\\msiexec.exe", drive: drive) != nil
        let plan = DockInstallScripts.plan(found, done: { run in
            DockInstallScripts.marked(run, in: run.hive == .machine ? machineRegistry : userRegistry)
        }, exists: { resolve($0, drive: drive) != nil }, runnable: { process in
            if process.executable.lowercased().hasSuffix(".msi") && !msiexec { return "Wine msiexec.exe missing" }
            guard let file = resolve(process.executable, drive: drive) else { return "Invalid installer path" }
            if file.pathExtension.lowercased() == "exe" {
                let url = file
                guard let handle = try? FileHandle(forReadingFrom: url) else { return "Cannot read installer" }
                defer { try? handle.close() }
                guard let dos = try? handle.read(upToCount: 64), dos.count == 64,
                      dos[0] == 0x4d, dos[1] == 0x5a else { return "Invalid Windows executable" }
                let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(dos[60 + $1]) << ($1 * 8) }
                guard (64...(1 << 20)).contains(offset), (try? handle.seek(toOffset: offset)) != nil,
                      let pe = try? handle.read(upToCount: 6), pe.count == 6,
                      pe.starts(with: [0x50, 0x45, 0, 0]) else { return "Invalid PE header" }
                let machine = UInt16(pe[4]) | (UInt16(pe[5]) << 8)
                if machine == 0x14c && !FileManager.default.fileExists(atPath:
                    Bundle.main.bundleURL.appendingPathComponent("i386-windows/ntdll.dll").path) {
                    return "32-bit Wine/WoW64 missing"
                }
            }
            return nil
        })
        if let blocked = plan.first(where: { $0.status == .missing || $0.status == .unsupported }) {
            throw PreparationError.unavailable("Steam prerequisite unavailable: "
                + DockInstallScripts.label(blocked.process.run)
                + (blocked.reason.map { " (\($0))" } ?? " (file missing)")
                + ". Verify the game installation before starting.")
        }
        let pending = plan.filter { $0.status == .pending }.map(\.process)
        guard !pending.isEmpty else { return nil }
        let cmd = drive.appendingPathComponent("windows/system32/cmd.exe")
        guard FileManager.default.fileExists(atPath: cmd.path) else {
            throw PreparationError.unavailable("The Wine command interpreter cmd.exe is missing; cannot run Steam prerequisites.")
        }
        // The host handles service start only; no client sign-in occurs in the
        // prerequisite session. Do not share the game's large-memory layout.
        _ = try MadeiraDock.stageHost()
        let batch = DockInstallScripts.batch(pending,
            resultFile: "C:\\" + stem(appID) + ".result",
            services: .start(executable: "C:\\windows\\system32\\dockhost.exe"))
        let saved = try JSONEncoder().encode(pending.map(\.run))
        let planURL = planFile(appID, prefix: prefix)
        try saved.write(to: planURL, options: .atomic)
        try? FileManager.default.removeItem(at: resultFile(appID, drive: drive))
        try batch.write(to: scriptFile(appID, drive: drive), atomically: true, encoding: .utf8)
        return Stage(command: cmd, appID: appID, count: pending.count)
    }

    static func progress(appID: UInt32, prefix: URL) -> String? {
        let result = resultFile(appID, drive: prefix.appendingPathComponent("drive_c", isDirectory: true))
        guard let data = try? Data(contentsOf: result), data.count < 32768 else { return nil }
        let parsed = DockInstallScripts.results(String(decoding: data, as: UTF8.self))
        if let running = parsed.running {
            return "Installing Steam prerequisite \(running) of \(max(running, parsed.total))..."
        }
        if parsed.ended { return "Steam prerequisites finished; waiting for Wine to close..." }
        return parsed.total > 0 ? "Preparing Steam prerequisites..." : nil
    }
}


/// Steam's numeric dockhost report drives progress, not the appearance of a
/// generic Wine desktop frame. A validated LaunchApp result is still not
/// proof of a frame originating from the game's own window.
enum IDeckDockStartStatus {
    static func text(_ fields: [String: String], waited: TimeInterval) -> String {
        if fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
            return "Steam rejected the game's launch option."
        }
        if fields["launch-update-wait"] != nil && fields["launch-update-ready"] == nil {
            return "Steam is installing required game content..."
        }
        if fields["launch-session-wait"] != nil && fields["launch-client-error"] == "35" {
            return "Waiting for Steam to release another game session..."
        }
        if fields["launch-config-wait"] != nil {
            return "Steam is loading the game's launch configuration..."
        }
        if fields["launch-client-error"] == "0" {
            return "Steam launched the game; waiting for graphics..."
        }
        if fields["ceg-request"] != nil && fields["ceg-result"] == nil {
            return "Steam is preparing the game's executable..."
        }
        if fields["session-offline-listed"] == "1" {
            return "Steam confirmed the game's offline license..."
        }
        if fields["session-offline-requested"] != nil || fields["session-offline-fallback"] != nil {
            return "Steam is attempting offline sign-in..."
        }
        if fields["session-requested-app-listed"] == "1" {
            return "Steam confirmed the game's license..."
        }
        if fields["session-authenticated-online"] == "1" {
            return "Steam signed in; checking the game license..."
        }
        if fields["session-native-token-submitted"] != nil ||
           fields["session-logon-start-result"] != nil {
            return "Signing in to Steam..."
        }
        if fields["probe-start-bits"] != nil { return "Loading the Steam client..." }
        return waited >= 30 ? "Still initializing Madeira Dock..." : "Starting Madeira Dock..."
    }
}
