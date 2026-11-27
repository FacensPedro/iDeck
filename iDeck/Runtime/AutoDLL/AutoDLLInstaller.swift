// AutoDLLManager: install, verify, pending DLLs, Wine log and undo.
// Split from AutoDLLManager.swift (iDeck 3.0 architecture).

import Foundation

extension AutoDLLManager {
    struct Installed: Codable, Equatable {
        var program: String
        var files: [String]
        var date: Date
    }

    static var ledgerURL: URL { cacheRoot.appendingPathComponent("installed.json") }

    static func ledger() -> [Installed] {
        (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode([Installed].self, from: $0) } ?? []
    }

    static func saveLedger(_ entries: [Installed]) {
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: ledgerURL, options: .atomic)
    }

    /// DLLs the Wine log of a failed start named as missing (c0000135): the next start
    /// gets them. Kept per program.
    static let pendingKey = "autoDLL.pending.v1"

    static func notePending(_ dlls: [String], program: URL) {
        let wanted = dlls.filter { component(for: $0) != nil }
        guard !wanted.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String]] ?? [:]
        all[program.path] = Array(Set((all[program.path] ?? []) + wanted.map { $0.lowercased() })).sorted()
        UserDefaults.standard.set(all, forKey: pendingKey)
        wanted.compactMap(component(for:)).forEach(prefetch)
        AppLog.record("[auto-dll] \(program.lastPathComponent): \(wanted.joined(separator: ", ")) will be installed at the next start")
    }

    /// Before the launch: copies cached DLLs the check found missing, verifies, and
    /// starts downloads for the rest. Returns a line for the log and report.
    @discardableResult
    static func resolve(_ result: DependencyCheck.Result, program: URL, prefix: URL) -> String? {
        lastProgram = program
        let pending = (UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String]])?[program.path] ?? []
        let missing = Array(Set(result.missing.map { $0.lowercased() } + pending)).sorted()
        guard !missing.isEmpty else { return nil }
        let machine: UInt16 = result.machine == 0x014C ? 0x014C : 0x8664
        let fm = FileManager.default
        let folder = program.deletingLastPathComponent()
        var copied: [String] = [], waiting: [String] = [], unknown: [String] = []
        for dll in missing {
            let file = dll.hasSuffix(".dll") ? dll : dll + ".dll"
            guard let component = component(for: file) else { unknown.append(file); continue }
            guard isCached(component) else { prefetch(component); waiting.append(file); continue }
            let source = cacheFolder(component, machine: machine).appendingPathComponent(file)
            let target = folder.appendingPathComponent(file)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            if (try? fm.copyItem(at: source, to: target)) != nil { copied.append(file) }
        }
        // Verify: a copy that the program still cannot use is taken back.
        if !copied.isEmpty {
            let runtime = DependencyCheck.runtimeFolder(for: result.machine) ?? "arm64ec-windows"
            let system = prefix.appendingPathComponent("drive_c/windows").appendingPathComponent(machine == 0x014C ? "syswow64" : "system32")
            if let again = DependencyCheck.check(program: program, systemFolders: [MadeiraRuntime.file(runtime), system]) {
                let still = Set(again.missing.map { $0.lowercased() } + again.wrongArchitecture.map { $0.lowercased() })
                for file in copied where still.contains(file) {
                    try? fm.removeItem(at: folder.appendingPathComponent(file))
                }
                copied.removeAll { still.contains($0) }
                DependencyCheck.last = again
            }
            var entries = ledger()
            entries.append(Installed(program: program.path, files: copied.map { folder.appendingPathComponent($0).path }, date: Date()))
            saveLedger(entries)
        }
        if !copied.isEmpty || waiting.isEmpty {
            var all = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String]] ?? [:]
            all[program.path] = waiting.isEmpty ? nil : waiting
            UserDefaults.standard.set(all, forKey: pendingKey)
        }
        var parts: [String] = []
        if !copied.isEmpty { parts.append("installed " + copied.joined(separator: ", ")) }
        if !waiting.isEmpty { parts.append("downloading for the next start " + waiting.joined(separator: ", ")) }
        if !unknown.isEmpty { parts.append("no official source known for " + unknown.joined(separator: ", ")) }
        let line = program.lastPathComponent + ": " + parts.joined(separator: "; ")
        AppLog.record("[auto-dll] " + line)
        return line
    }

    /// The program the last launch checked, for a failed start's Wine log.
    nonisolated(unsafe) static var lastProgram: URL?

    /// Catalog DLLs that a Wine log names as not found ("[dll-missing] ... foo.dll ...
    /// status=c0000135"), read 1 MB at a time from the session's part of the log.
    static func missingInLog(_ logURL: URL?, since offset: Int64?) -> [String] {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = max(UInt64(max(offset ?? 0, 0)), end > 16 << 20 ? end - (16 << 20) : 0)
        try? handle.seek(toOffset: start)
        let marker = Data("c0000135".utf8)
        var found = Set<String>()
        let names = catalog.flatMap(\.dlls).map { $0 + ".dll" }
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            guard chunk.range(of: marker) != nil, let text = String(data: chunk, encoding: .utf8)?.lowercased() else { continue }
            for line in text.split(separator: "\n") where line.contains("c0000135") {
                for name in names where line.contains(name) { found.insert(name) }
            }
        }
        return found.sorted()
    }

    /// Removes every DLL this manager put in a game's folder. Returns how many.
    @discardableResult
    static func rollbackAll() -> Int {
        var removed = 0
        for entry in ledger() {
            for path in entry.files where (try? FileManager.default.removeItem(atPath: path)) != nil { removed += 1 }
        }
        saveLedger([])
        UserDefaults.standard.removeObject(forKey: pendingKey)
        AppLog.record("[auto-dll] undo: \(removed) DLL(s) removed from game folders")
        return removed
    }
}
