import Foundation

/// iDeck Auto DLL Manager. Before a game starts, the DLL check (DependencyCheck) lists
/// the DLLs its program imports that neither the game's folder nor Wine has. For each
/// one this manager:
/// 1. reads the program's architecture from the check (x86 = i386, x64; ARM64EC
///    programs use the x64 copies, as Windows on ARM does),
/// 2. finds the component that ships the DLL (the catalog below),
/// 3. downloads that component once, only from its publisher (Microsoft's download
///    server, checked by VisualCRuntimeBootstrap.isTrustedDownloadURL), into a cache
///    under Files › iDeck › DLL Cache, kept for every later game,
/// 4. copies the DLL of the right architecture next to the game's program, where
///    Windows and Wine look first, in the game's own prefix,
/// 5. checks the program again and takes back any copy that did not resolve its import,
/// 6. records every copy, so Settings › Windows runtime › Undo automatic DLLs removes them.
/// A DLL that appears only in the Wine log after a failed start (status c0000135) is
/// looked up the same way; its component is downloaded at once and the DLL is put in
/// place at the next start, which iDeck asks for ("start the game again"): iDeck needs a
/// fresh process for each Windows session, so it cannot restart the game by itself.
/// Visual C++ and .NET are not here: iDeck installs those before the launch already.
enum AutoDLLManager {
    struct Component {
        let id: String
        let title: String
        let url: URL
        let sizeRange: ClosedRange<Int64>
        let dlls: [String]
    }

    /// Microsoft's DirectX End-User Runtime (June 2010): D3DX 9/10/11, the HLSL compiler,
    /// XInput 1.1-1.3, XAudio2 2.0-2.7, X3DAudio, XACT and XAPOFX, both architectures.
    static let directX = Component(
        id: "directx-jun2010", title: "DirectX End-User Runtime (June 2010)",
        url: NativeD3DX.redistURL, sizeRange: 50_000_000...150_000_000,
        dlls: (24...43).map { "d3dx9_\($0)" } + (33...43).map { "d3dx10_\($0)" } + ["d3dx11_42", "d3dx11_43"]
            + (33...43).map { "d3dcompiler_\($0)" } + ["d3dcsx_42", "d3dcsx_43"]
            + ["xinput1_1", "xinput1_2", "xinput1_3", "xinput9_1_0"]
            + (0...7).map { "xaudio2_\($0)" } + (0...7).map { "x3daudio1_\($0)" }
            + (0...5).map { "xapofx1_\($0)" }
            + ["xactengine2_0", "xactengine2_1", "xactengine2_2", "xactengine2_3", "xactengine2_4", "xactengine2_5",
               "xactengine2_6", "xactengine2_7", "xactengine2_8", "xactengine2_9", "xactengine2_10"]
            + (0...7).map { "xactengine3_\($0)" })

    static let catalog: [Component] = [directX]

    static func component(for dll: String) -> Component? {
        let name = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
        return catalog.first { $0.dlls.contains(name) }
    }

    static var cacheRoot: URL {
        WindowsInstallerEnvironment.documents.appendingPathComponent("iDeck/DLL Cache", isDirectory: true)
    }

    static func cacheFolder(_ component: Component, machine: UInt16) -> URL {
        cacheRoot.appendingPathComponent(component.id, isDirectory: true)
            .appendingPathComponent(machine == 0x014C ? "x86" : "x64", isDirectory: true)
    }

    static let marker = ".ready"

    static func isCached(_ component: Component) -> Bool {
        [UInt16(0x014C), 0x8664].allSatisfy {
            FileManager.default.fileExists(atPath: cacheFolder(component, machine: $0).appendingPathComponent(marker).path)
        }
    }

    // MARK: Download and cache

    nonisolated(unsafe) private static var downloading: Set<String> = []

    /// Downloads the component once and keeps both architectures' DLLs.
    static func prepare(_ component: Component) async throws {
        if isCached(component) { return }
        let fm = FileManager.default
        var request = URLRequest(url: component.url)
        request.timeoutInterval = 180
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? fm.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, VisualCRuntimeBootstrap.isTrustedDownloadURL(final) else {
            throw NSError(domain: "iDeck.autodll", code: 1, userInfo: [NSLocalizedDescriptionKey: "untrusted or failed download"])
        }
        let size = (try fm.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard component.sizeRange.contains(size), VisualCRuntimeBootstrap.hasPE(temporary, machines: [0x014C]) else {
            throw NSError(domain: "iDeck.autodll", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected file (\(size) bytes)"])
        }
        let installer = temporary
        try await Task.detached(priority: .utility) {
            for machine: UInt16 in [0x014C, 0x8664] { try extract(component, from: installer, machine: machine) }
        }.value
        AppLog.record("[auto-dll] \(component.title) cached for later games")
    }

    private static func extract(_ component: Component, from installer: URL, machine: UInt16) throws {
        let fm = FileManager.default
        let folder = cacheFolder(component, machine: machine)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = component.dlls.map { $0 + ".dll" }
        var found = [Int32](repeating: 0, count: names.count)
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let copies = names.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } }
        let count = installer.path.withCString { source in
            folder.path.withCString { target in
                pointers.withUnsafeBufferPointer { list in
                    ideck_vcrt_extract_set(source, target, list.baseAddress, Int32(names.count), Int32(machine),
                                           &found, &message, capacity)
                }
            }
        }
        AppLog.record("[auto-dll] \(component.id) \(machine == 0x014C ? "x86" : "x64"): \(count) of \(names.count) DLLs (\(String(cString: message)))")
        guard count > 0 else { throw NSError(domain: "iDeck.autodll", code: Int(count)) }
        fm.createFile(atPath: folder.appendingPathComponent(marker).path, contents: Data())
    }

    /// Starts the download in the background (once at a time per component).
    static func prefetch(_ component: Component) {
        guard !isCached(component), !downloading.contains(component.id) else { return }
        downloading.insert(component.id)
        Task.detached(priority: .utility) {
            do { try await prepare(component) } catch {
                AppLog.record("[auto-dll] \(component.title): download failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { downloading.remove(component.id) }
        }
    }

    // MARK: Install, verify, roll back

    struct Installed: Codable, Equatable {
        var program: String
        var files: [String]
        var date: Date
    }

    static var ledgerURL: URL { cacheRoot.appendingPathComponent("installed.json") }

    static func ledger() -> [Installed] {
        (try? Data(contentsOf: ledgerURL)).flatMap { try? JSONDecoder().decode([Installed].self, from: $0) } ?? []
    }

    private static func saveLedger(_ entries: [Installed]) {
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
