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
