import Foundation

/// One ISO 8601 formatter for the whole app, made when iDeck opens. A formatter
/// made after a Windows session crashed iDeck inside ICU (udat_open read a locale
/// left behind by the finished Wine thread, 2.6.0 Dragon Age log): it must exist
/// before Wine ever runs and is never created again.
enum ISOStamp {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()  // guarded by lock
    nonisolated(unsafe) private static let local: ISO8601DateFormatter = {  // guarded by lock
        let f = ISO8601DateFormatter(); f.timeZone = .current; return f
    }()
    nonisolated(unsafe) private static let fraction: ISO8601DateFormatter = {  // guarded by lock
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func warmUp() { _ = string(Date()); _ = localString(Date()); _ = date("2000-01-01T00:00:00Z") }
    /// In the device's time zone.
    static func localString(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return local.string(from: date)
    }
    /// Parses with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fraction.date(from: text) ?? formatter.date(from: text)
    }
    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// The memory record of each finished game session: footprint at the end, the
/// session's peak, what iOS still had available and why the session ended.
/// The last `limit` sessions are kept for Bugs & logs (a report made after a
/// crash runs in a new process).
enum SessionMemory {
    struct Entry: Codable, Equatable {
        var game: String
        var launcher: String
        var started: Date
        var durationSeconds: Int
        var currentMiB: Int
        var peakMiB: Int
        var availableMiB: Int
        var reason: String

        var line: String {
            "\(ISOStamp.string(started)) \(launcher) \(game): \(durationSeconds)s, "
                + "RAM \(currentMiB) MiB at the end, peak \(peakMiB) MiB, available \(availableMiB) MiB — \(reason)"
        }
    }

    static let key = "diagnostics.sessionMemory.v1"
    static let limit = 20

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func record(_ entry: Entry) {
        var list = entries()
        list.append(entry)
        if list.count > limit { list.removeFirst(list.count - limit) }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
        AppLog.record("[memory] session record: " + entry.line)
    }

    /// For bug reports: one line per session, newest last.
    static var report: String { entries().map(\.line).joined(separator: "\n") }
}

/// What iDeck learned about each game from its own sessions, keyed by the
/// profile id ("steam:<appID>", a program's path, a store prefix and ID).
/// Unlike GameRecommendations (settings tested by hand for known games) this
/// covers every game: crashes, the memory it needed and the JIT pool that
/// last worked, and it steers the next launch (MadeiraWinePool.sizeMB).
enum GameCompatibility {
    struct Profile: Codable, Equatable {
        var sessions = 0
        var crashes = 0
        /// Crashes in a row since the last clean exit.
        var consecutiveCrashes = 0
        var lastNTStatus: UInt32?
        var lastReason = ""
        var peakMiB = 0
        var lowestAvailableMiB = 0
        /// The pool of the last session that exited cleanly.
        var lastGoodPoolMiB = 0
        /// The pool the last session started with.
        var lastPoolMiB = 0
        var updated = Date()
    }

    static let key = "compatibility.games.v1"
    static let maximumGames = 200
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Profile]?

    private static func load() -> [String: Profile] {
        if let cache { return cache }
        let decoded = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: Profile].self, from: $0) } ?? [:]
        cache = decoded
        return decoded
    }

    private static func update(_ game: String, _ change: (inout Profile) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var profile = all[game] ?? Profile()
        change(&profile)
        profile.updated = Date()
        all[game] = profile
        if all.count > maximumGames,
           let oldest = all.min(by: { $0.value.updated < $1.value.updated })?.key { all[oldest] = nil }
        cache = all
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func profile(_ game: String) -> Profile? {
        lock.lock(); defer { lock.unlock() }
        return load()[game]
    }

    static func notePool(_ game: String, poolMiB: Int) {
        update(game) { $0.lastPoolMiB = poolMiB }
    }

    static func noteMemory(_ game: String, peakMiB: Int, availableMiB: Int) {
        update(game) { profile in
            profile.peakMiB = max(profile.peakMiB, peakMiB)
            profile.lowestAvailableMiB = profile.lowestAvailableMiB == 0
                ? availableMiB : min(profile.lowestAvailableMiB, availableMiB)
        }
    }

    static func noteSessionEnd(_ game: String, ntstatus: UInt32?, reason: String) {
        let crashed = (ntstatus ?? 0) != 0 || reason.hasPrefix("Execution Error")
        update(game) { profile in
            profile.sessions += 1
            profile.lastReason = String(reason.prefix(200))
            profile.lastNTStatus = ntstatus
            if crashed {
                profile.crashes += 1
                profile.consecutiveCrashes += 1
            } else {
                profile.consecutiveCrashes = 0
                MemoryGuard.noteCleanExit(game)
                if profile.lastPoolMiB > 0 { profile.lastGoodPoolMiB = profile.lastPoolMiB }
            }
        }
        AppLog.record("[compat] \(game): \(crashed ? "crash" : "clean exit")"
                      + (ntstatus.map { " ntstatus=0x\(String($0, radix: 16, uppercase: true))" } ?? ""))
    }

    /// For bug reports: the current game's learned profile.
    static func report(_ game: String) -> String? {
        guard let p = profile(game) else { return nil }
        return "\(game): \(p.sessions) session(s), \(p.crashes) crash(es) (\(p.consecutiveCrashes) in a row), "
            + "peak \(p.peakMiB) MiB, lowest available \(p.lowestAvailableMiB) MiB, "
            + "pool \(p.lastPoolMiB) MB (last good \(p.lastGoodPoolMiB) MB)"
    }
}

/// Games iOS ended (iDeck stopped while they ran, with little memory left at the last
/// sample) and what iDeck does about it. The next launch runs DXMT with one frame in
/// flight; after two such ends in a row a launch is held once with an explanation, and
/// starting the game again within three minutes goes ahead. A clean exit clears it.
enum MemoryGuard {
    static let killsKey = "compatibility.memoryKills.v1"
    static let overrideKey = "compatibility.memoryOverride.v1"
    /// What the session sampler keeps while a game runs, read after iDeck restarts.
    static let sessionGameKey = "diagnostics.sessionGameID"
    static let lowestAvailableKey = "diagnostics.sessionLowestAvailableMiB"
    static let peakKey = "diagnostics.sessionPeakMiB"
    /// Below this, at the last sample before iDeck stopped, the stop counts as iOS's memory limit.
    static let lowMemoryMiB = 512
    static let blockAfterKills = 2
    static let overrideSeconds: TimeInterval = 180

    static func kills(_ game: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: killsKey) as? [String: Int])?[game] ?? 0
    }

    private static func setKills(_ game: String, _ count: Int) {
        var all = (UserDefaults.standard.dictionary(forKey: killsKey) as? [String: Int]) ?? [:]
        all[game] = count > 0 ? count : nil
        if all.count > 200, let any = all.keys.first(where: { $0 != game }) { all[any] = nil }
        UserDefaults.standard.set(all, forKey: killsKey)
    }

    static func noteCleanExit(_ game: String) {
        if kills(game) > 0 { setKills(game, 0) }
    }

    /// Whether the last sample before iDeck stopped leaves memory as the likely cause.
    static func wasMemoryKill(lowestAvailableMiB: Int) -> Bool {
        lowestAvailableMiB >= 0 && lowestAvailableMiB < lowMemoryMiB
    }

    /// At iDeck's start, when the last session ended with the app: record it for the game.
    static func checkAfterAppRestart(sessionWasRunning: Bool) {
        let defaults = UserDefaults.standard
        guard sessionWasRunning, let game = defaults.string(forKey: sessionGameKey), !game.isEmpty else { return }
        let lowest = defaults.object(forKey: lowestAvailableKey) as? Int ?? -1
        let peak = defaults.object(forKey: peakKey) as? Int ?? -1
        let memory = wasMemoryKill(lowestAvailableMiB: lowest)
        let reason = memory
            ? "iOS stopped iDeck for lack of memory while the game ran (\(lowest) MiB left at the last sample)"
            : "iDeck stopped while the game ran (\(lowest) MiB left at the last sample: not memory)"
        GameCompatibility.noteSessionEnd(game, ntstatus: nil, reason: "Execution Error: " + reason)
        if peak > 0 { GameCompatibility.noteMemory(game, peakMiB: peak, availableMiB: max(lowest, 0)) }
        if memory { setKills(game, kills(game) + 1) }
        LaunchReport.finish(game: game, reason: reason, ntstatus: nil, runtimeTrap: false, appStopped: true)
        AppLog.record("[memory-guard] \(game): \(reason); peak \(peak) MiB; memory stops in a row \(kills(game))")
        defaults.removeObject(forKey: sessionGameKey)
    }

    /// Whether this game should run with the lighter memory settings.
    static func lighten(_ game: String) -> Bool { kills(game) > 0 }

    /// A message when the launch is held, nil to go ahead. A held launch arms the
    /// override: the same game started again within three minutes goes ahead.
    static func holdMessage(_ game: String) -> String? {
        let count = kills(game)
        guard count >= blockAfterKills else { return nil }
        var overrides = (UserDefaults.standard.dictionary(forKey: overrideKey) as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        if let armed = overrides[game], now - armed < overrideSeconds {
            overrides[game] = nil
            UserDefaults.standard.set(overrides, forKey: overrideKey)
            AppLog.record("[memory-guard] \(game): started again within 3 minutes, going ahead")
            return nil
        }
        overrides = overrides.filter { now - $0.value < overrideSeconds }
        overrides[game] = now
        UserDefaults.standard.set(overrides, forKey: overrideKey)
        let peak = GameCompatibility.profile(game)?.peakMiB ?? 0
        AppLog.record("[memory-guard] \(game): launch held, \(count) memory stops in a row, peak \(peak) MiB")
        return tr("Cannot launch: iOS closed iDeck for lack of memory the last %d times this game ran (up to %d MiB). Lower the game's resolution on its page, close other apps, then start it again. Starting it again within 3 minutes goes ahead anyway.", count, peak)
    }
}

/// Steam games that need Valve's Windows client: started without it, they asked for it
/// (steamworks' SteamAPI_RestartAppIfNecessary opens steam://run/<app id>; a failed
/// SteamAPI_Init prints "[S_API FAIL]") and closed within a minute. Their later launches
/// go through Madeira Dock, Steam's client, whatever the direct list says.
enum SteamClientNeed {
    static let key = "steam.needsClient.v1"
    static let quickExitSeconds: TimeInterval = 60

    /// What the game's part of the Wine log shows, lower-cased.
    static func markers(appID: UInt32) -> [String] {
        ["steam://run/\(appID)", "steam://rungameid/\(appID)", "[s_api fail]"]
    }

    static func needs(_ appID: UInt32) -> Bool {
        (UserDefaults.standard.array(forKey: key) as? [Int] ?? []).contains(Int(appID))
    }

    static func note(_ appID: UInt32) {
        var list = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        guard !list.contains(Int(appID)) else { return }
        list.append(Int(appID))
        UserDefaults.standard.set(list, forKey: key)
        AppLog.record("[steam-client] app=\(appID) asked for Steam's client when started without it: started through Steam from now on")
    }
}

/// Before a game starts: the DLLs its program (and the DLLs it ships that the program
/// loads) import, looked up the way Wine will look: the game's folder first, then the
/// Windows runtime of the program's architecture (i386-windows for 32-bit programs,
/// arm64ec-windows for 64-bit ones) and the prefix's system folder. Reports what is
/// missing and any DLL in the game's folder built for another architecture (Windows
/// itself refuses those: 0xC000007B). Nothing is changed; the result is logged as
/// [deps], kept for bug reports, and added to the reason of a session that ends early.
enum DependencyCheck {
    struct Result: Equatable {
        var program: String
        var machine: UInt16
        var checked = 0
        var missing: [String] = []
        var wrongArchitecture: [String] = []

        var problems: Bool { !missing.isEmpty || !wrongArchitecture.isEmpty }

        var summary: String {
            var parts: [String] = []
            if !missing.isEmpty { parts.append("missing " + missing.prefix(8).joined(separator: ", ")) }
            if !wrongArchitecture.isEmpty { parts.append("wrong architecture " + wrongArchitecture.prefix(8).joined(separator: ", ")) }
            return parts.joined(separator: "; ")
        }
    }

    static let reportKey = "diagnostics.dependencyCheck"
    nonisolated(unsafe) static var last: Result?

    /// Libraries Wine or iDeck provide at session start, or that are resolved by name
    /// without a file (API sets): never reported missing.
    static let providedPrefixes = ["api-ms-", "ext-ms-", "msvcp", "msvcr", "vcruntime", "vcomp", "concrt", "ucrtbase",
                                   "mfc", "d3dx", "d3dcompiler", "xinput", "xaudio", "x3daudio", "xapofx", "steam_api",
                                   "openal", "physxloader", "nvcuda", "nvapi", "amd_ags", "galaxy"]

    // MARK: PE reading

    struct PEInfo { var machine: UInt16; var imports: [String] }

    /// The COFF machine and the import table's DLL names (lower-cased), nil when not PE.
    static func read(_ url: URL) -> PEInfo? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 0x40 else { return nil }
        func u16(_ o: Int) -> UInt16? { o >= 0 && o + 2 <= data.count ? UInt16(data[o]) | UInt16(data[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            return UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        guard data[0] == 0x4D, data[1] == 0x5A, let peOffset = u32(0x3C).map(Int.init),
              u32(peOffset) == 0x0000_4550, let machine = u16(peOffset + 4),
              let sectionCount = u16(peOffset + 6).map(Int.init), let optionalSize = u16(peOffset + 20).map(Int.init),
              let magic = u16(peOffset + 24) else { return nil }
        let optional = peOffset + 24
        let directories = optional + (magic == 0x20B ? 112 : 96)
        let sectionTable = optional + optionalSize
        var sections: [(va: UInt32, size: UInt32, raw: UInt32)] = []
        for i in 0..<min(sectionCount, 96) {
            let s = sectionTable + 40 * i
            guard let vsize = u32(s + 8), let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { break }
            sections.append((va, max(vsize, rawSize), raw))
        }
        func offset(_ rva: UInt32) -> Int? {
            for s in sections where rva >= s.va && rva < s.va &+ s.size {
                return Int(s.raw) + Int(rva - s.va)
            }
            return nil
        }
        var imports: [String] = []
        if magic == 0x10B || magic == 0x20B, let importRVA = u32(directories + 8), importRVA != 0, var d = offset(importRVA) {
            for _ in 0..<512 {
                guard let nameRVA = u32(d + 12), nameRVA != 0, let nameOffset = offset(nameRVA) else { break }
                var end = nameOffset
                while end < data.count, data[end] != 0, end - nameOffset < 256 { end += 1 }
                let name = String(decoding: data[nameOffset..<end], as: UTF8.self).lowercased()
                if !name.isEmpty && !imports.contains(name) { imports.append(name) }
                d += 20
            }
        }
        return PEInfo(machine: machine, imports: imports)
    }

    // MARK: The check

    /// Whether a library built for `library` loads into a program built for `program`.
    static func compatible(program: UInt16, library: UInt16) -> Bool {
        switch program {
        case 0x014C: return library == 0x014C
        case 0x8664, 0xA641: return library == 0x8664 || library == 0xA641 || library == 0xAA64
        default: return true
        }
    }

    static func runtimeFolder(for machine: UInt16) -> String? {
        switch machine {
        case 0x014C: return "i386-windows"
        case 0x8664, 0xA641, 0xAA64: return "arm64ec-windows"
        default: return nil
        }
    }

    /// Checks `program`. `systemFolders` are where Wine's own DLLs are, for the
    /// program's architecture; the game's folder is searched first.
    static func check(program: URL, systemFolders: [URL]) -> Result? {
        guard let info = read(program) else { return nil }
        let gameFolder = program.deletingLastPathComponent()
        var result = Result(program: program.lastPathComponent, machine: info.machine)
        let localNames: [String: URL] = Dictionary(
            ((try? FileManager.default.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "dll" }.map { ($0.lastPathComponent.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        var queue = info.imports
        var seen = Set<String>()
        var localScanned = 0
        while let name = queue.first {
            queue.removeFirst()
            guard seen.insert(name).inserted, seen.count <= 400 else { continue }
            result.checked += 1
            // An import may name a path relative to the program ("Core\\Activation64.dll",
            // EA's activation library): look it up there, by each component's case.
            var localFile = localNames[name]
            if localFile == nil, name.contains("\\") || name.contains("/") {
                var url: URL? = gameFolder
                for part in name.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init) where !part.isEmpty {
                    guard let folder = url, part != "..",
                          let match = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                            .first(where: { $0.lowercased() == part }) else { url = nil; break }
                    url = folder.appendingPathComponent(match)
                }
                localFile = url
            }
            if let local = localFile {
                guard let libraryInfo = read(local) else { continue }
                if !compatible(program: info.machine, library: libraryInfo.machine) {
                    result.wrongArchitecture.append(local.lastPathComponent)
                } else if localScanned < 64 {
                    // A DLL the game ships brings its own imports.
                    localScanned += 1
                    queue.append(contentsOf: libraryInfo.imports)
                }
                continue
            }
            if providedPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let found = systemFolders.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }
            if !found { result.missing.append(name) }
        }
        return result
    }

    /// The check for a launch: logged, kept for the bug report and for the session's end.
    @discardableResult
    static func run(program: URL, prefix: URL) -> Result? {
        guard let machine = read(program)?.machine, let runtime = runtimeFolder(for: machine) else { return nil }
        let system = prefix.appendingPathComponent("drive_c/windows")
            .appendingPathComponent(machine == 0x014C ? "syswow64" : "system32")
        var folders = [MadeiraRuntime.file(runtime), system]
        if runtime == "arm64ec-windows" { folders.append(MadeiraRuntime.file("aarch64-windows")) }
        guard let result = check(program: program, systemFolders: folders) else { return nil }
        last = result
        let architecture = machine == 0x014C ? "32-bit" : "64-bit"
        let line = "\(result.program) (\(architecture)): \(result.checked) DLL(s) checked"
            + (result.problems ? ", " + result.summary : ", all found")
        UserDefaults.standard.set(line, forKey: reportKey)
        AppLog.record("[deps] " + line)
        return result
    }
}


/// Games whose session showed Metal GPU faults (a command buffer that ended in error:
/// GPU hang, timeout, page fault, or later submissions ignored because of them). The
/// driver then drops the game's work and the picture freezes or goes black. The
/// game's MetalFX upscaling and frame generation, the heaviest GPU work iDeck adds,
/// are turned off in its profile, and the next launch runs one frame in flight.
enum GPUFaultGuard {
    static let key = "compatibility.gpuFaults.v1"
    /// Lower-cased, as Metal's error descriptions and madeira-d3d12's log write them.
    static let markers = ["command buffer ended in error", "caused gpu hang", "gpu timeout error",
                          "submissionsignored", "ignored (for causing prior/excessive gpu errors)",
                          "caused gpu address fault", "kiogpucommandbuffercallbackerrortimeout"]

    static func faulted(_ game: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(game)
    }

    /// Records the game; true when this is new. A clean session that shows no fault clears it.
    @discardableResult
    static func note(_ game: String, faulted: Bool) -> Bool {
        var games = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !faulted {
            if games.contains(game) { games.removeAll { $0 == game }; UserDefaults.standard.set(games, forKey: key) }
            return false
        }
        guard !games.contains(game) else { return false }
        games.append(game)
        if games.count > 200 { games.removeFirst(games.count - 200) }
        UserDefaults.standard.set(games, forKey: key)
        AppLog.record("[gpu-fault] \(game): Metal reported GPU errors in this session")
        return true
    }
}

/// One record per game launch: when it started, how long until its first image, the
/// stage it reached, how it ended and whose failure that was (the game, the Windows
/// runtime, the store, or iDeck itself), with its memory peak and the DLL check.
/// Kept in UserDefaults (the last 20), so a launch that ended with iDeck is recorded
/// at the next start; logged as [launch-report] and listed in bug reports.
enum LaunchReport {
    enum Fault: String, Codable {
        case none = "no failure"
        case game = "the game"
        case runtime = "the Windows runtime"
        case store = "the store or its licence"
        case iDeck = "iDeck"
        case unclear = "unclear"
    }

    struct Entry: Codable, Equatable {
        var game: String
        var started: Date
        var secondsToFirstImage: Int?
        var durationSeconds: Int
        var stage: String
        var ending: String
        var fault: Fault
        var peakMiB: Int
        var dllCheck: String?

        var line: String {
            "\(ISOStamp.string(started)) \(game): first image "
                + (secondsToFirstImage.map { "after \($0) s" } ?? "never")
                + ", ran \(durationSeconds) s, stage \"\(stage)\", fault: \(fault.rawValue), peak \(peakMiB) MiB"
                + (dllCheck.map { ", DLLs: \($0)" } ?? "") + " — " + ending
        }
    }

    static let key = "diagnostics.launchReports.v1"
    static let startedKey = "diagnostics.launch.started"
    static let firstImageKey = "diagnostics.launch.firstImage"
    static let titleKey = "diagnostics.launch.title"
    static let limit = 20

    static func begin(title: String) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: startedKey)
        defaults.removeObject(forKey: firstImageKey)
        defaults.set(title, forKey: titleKey)
    }

    static func firstImage() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: firstImageKey) == nil,
              let started = defaults.object(forKey: startedKey) as? Double else { return }
        let seconds = Int(Date().timeIntervalSince1970 - started)
        defaults.set(seconds, forKey: firstImageKey)
        AppLog.record("[launch-report] first image \(seconds) s after the start")
    }

    /// Whose failure an ending was. Pure, for tests.
    static func classify(reason: String, ntstatus: UInt32?, sawImage: Bool, appStopped: Bool, runtimeTrap: Bool) -> Fault {
        let lower = reason.lowercased()
        if appStopped { return .iDeck }
        if lower.hasPrefix("steam: ") || lower.contains("licence") || lower.contains("license")
            || lower.contains("steam's windows client") || lower.contains("anti-cheat") { return .store }
        if lower.hasPrefix("cannot launch") || lower.contains("jit pool") { return .iDeck }
        if runtimeTrap || ntstatus == 0xC0000135 || ntstatus == 0xC000007B || lower.contains("dll check before the start")
            || lower.contains("gpu reported errors") || lower.contains("self-modifying") { return .runtime }
        let crashed = (ntstatus ?? 0) != 0 || lower.hasPrefix("execution error")
        if !crashed { return sawImage ? .none : .unclear }
        // A crash after the game drew is most often the game's own code path under
        // translation; before any image, the runtime never got the game running.
        return sawImage ? .game : .runtime
    }

    static func finish(game: String, reason: String, ntstatus: UInt32?, runtimeTrap: Bool, appStopped: Bool = false) {
        let defaults = UserDefaults.standard
        guard let started = defaults.object(forKey: startedKey) as? Double else { return }
        let first = defaults.object(forKey: firstImageKey) as? Int
        let title = defaults.string(forKey: titleKey) ?? game
        let fault = classify(reason: reason, ntstatus: ntstatus, sawImage: first != nil, appStopped: appStopped, runtimeTrap: runtimeTrap)
        let entry = Entry(game: title, started: Date(timeIntervalSince1970: started), secondsToFirstImage: first,
                          durationSeconds: max(0, Int(Date().timeIntervalSince1970 - started)),
                          stage: String((defaults.string(forKey: "diagnostics.session.stage") ?? "unknown").prefix(120)),
                          ending: String(reason.prefix(300)), fault: fault,
                          peakMiB: defaults.object(forKey: "diagnostics.sessionPeakMiB") as? Int ?? 0,
                          dllCheck: (DependencyCheck.last?.problems ?? false) ? DependencyCheck.last?.summary : nil)
        var list = entries()
        list.append(entry)
        if list.count > limit { list.removeFirst(list.count - limit) }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
        defaults.removeObject(forKey: startedKey)
        AppLog.record("[launch-report] " + entry.line)
    }

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static var report: String { entries().suffix(8).map(\.line).joined(separator: "\n") }
}

/// The language chosen for one game on its page ("Game language"), by profile id
/// ("steam:<app>", "epic:<app>", "gog:<id>", "ea:<offer>", "ubisoft:<id>"), as a
/// BCP 47 tag ("pt-BR"). None means automatic: iDeck's own language, as before.
/// Stores install or pass one language for both voices and subtitles; the game
/// uses it for whichever it has. Steam alone says per language which it has.
enum GameLanguage {
    static let key = "game-languages.v1"
    /// Languages the store listed for a game, kept when known (Ubisoft's manifest).
    static let knownKey = "game-languages.known.v1"

    /// BCP 47 tags with their Steam API names, in Steam's order.
    static let all: [(tag: String, steam: String)] = [
        ("ar-SA", "arabic"), ("bg-BG", "bulgarian"), ("zh-CN", "schinese"), ("zh-TW", "tchinese"),
        ("cs-CZ", "czech"), ("da-DK", "danish"), ("nl-NL", "dutch"), ("en-US", "english"),
        ("fi-FI", "finnish"), ("fr-FR", "french"), ("de-DE", "german"), ("el-GR", "greek"),
        ("hu-HU", "hungarian"), ("id-ID", "indonesian"), ("it-IT", "italian"), ("ja-JP", "japanese"),
        ("ko-KR", "koreana"), ("nb-NO", "norwegian"), ("pl-PL", "polish"), ("pt-PT", "portuguese"),
        ("pt-BR", "brazilian"), ("ro-RO", "romanian"), ("ru-RU", "russian"), ("es-ES", "spanish"),
        ("es-MX", "latam"), ("sv-SE", "swedish"), ("th-TH", "thai"), ("tr-TR", "turkish"),
        ("uk-UA", "ukrainian"), ("vi-VN", "vietnamese"),
    ]

    /// The languages the Game language choice offers.
    static let supported = ["pt-BR", "es-ES", "en-US"]

    static func choice(_ profileID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[profileID]
    }

    static func choose(_ profileID: String, _ tag: String?) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[profileID] = tag
        UserDefaults.standard.set(all, forKey: key)
        AppLog.record("[game-language] \(profileID): \(tag ?? "automatic")")
        if profileID.hasPrefix("steam:"), let app = UInt32(profileID.dropFirst(6)) {
            SteamLanguage.chooseForGame(app, tag.flatMap(steamName))
        }
    }

    static func steamName(_ tag: String) -> String? { all.first { $0.tag.lowercased() == tag.lowercased() }?.steam }
    static func tag(steam: String) -> String? { all.first { $0.steam == steam.lowercased() }?.tag }

    /// The game's language for a launch: its choice, else iDeck's own.
    static func locale(_ profileID: String, separator: String) -> String {
        if let tag = choice(profileID) { return tag.replacingOccurrences(of: "-", with: separator) }
        return AppLanguage.gameLocale(separator: separator)
    }

    /// The language's own name ("Português (Brasil)").
    static func name(_ tag: String) -> String {
        let locale = Locale(identifier: tag)
        return locale.localizedString(forIdentifier: tag).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? tag
    }

    static func rememberKnown(_ profileID: String, _ tags: [String]) {
        var known = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: [String]] ?? [:]
        known[profileID] = tags
        UserDefaults.standard.set(known, forKey: knownKey)
    }

    static func known(_ profileID: String) -> [String]? {
        (UserDefaults.standard.dictionary(forKey: knownKey) as? [String: [String]])?[profileID]
    }
}
