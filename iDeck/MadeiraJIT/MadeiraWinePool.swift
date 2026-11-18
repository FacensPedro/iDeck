import Darwin
import os
import Foundation

/// Madeira's launch steps for the Wine JIT pool (ContentView, "Step 1" and
/// "Step 1b"), line for line: the pool size (896 MB, or madeira.cfg pool),
/// StikJITHelper.allocatePool, the WINE_IOS_JIT_* exports, and the early detach
/// of the debugger right after, while the VM map is still small.
enum MadeiraWinePool {
    private static let preparationLock = NSLock()
    private static let exports = ["WINE_IOS_JIT_RX", "WINE_IOS_JIT_RW", "WINE_IOS_JIT_SIZE",
                                  "WINE_IOS_JIT_HOLE", "WINE_IOS_JIT_HOLE2", "WINE_IOS_JIT_TAIL_REGION"]
    /// A game's explicit Madeira configuration wins. The per-executable JIT
    /// pool list then takes precedence over the global Madeira/default pool,
    /// so a title that needs a smaller contiguous RX mapping does not silently
    /// inherit a global 896 MB request.
    static var sizeMB: Int {
        if let txt = MadeiraConfig.gameValue("pool"),
           let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)), (256...1152).contains(mb) {
            return mb
        }
        if let mb = JITPoolList.size(forCurrentGame: ()) { return mb }
        if let txt = MadeiraConfig.get("pool"),
           let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)), (256...1152).contains(mb) {
            return mb
        }
        // Without a choice in Settings: 560 MB, the largest run these devices
        // actually fit beside the main thread's stack (624 was shrunk to 560 by
        // ml1036 on every launch)
        // (896 was always shrunk, here to as little as 336 MB, after the start
        // had already planned for it).
        let chosen = UserDefaults.standard.integer(forKey: "wineJITPoolMiB")
        if (256...1152).contains(chosen) { return chosen }
        return automaticSizeMB(default: 560)
    }

    /// Steps the automatic pool may take, largest first.
    static let automaticSteps = [896, 768, 640, 560, 512, 384, 256]

    /// The automatic pool (no choice in a game config, jit-pool.txt or Settings),
    /// fitted to this run: what the current game needed before (GameCompatibility),
    /// the memory iOS still gives the process and the address space beside the
    /// guest window. An explicit choice is never changed.
    static func automaticSizeMB(default base: Int) -> Int {
        var size = base
        var why: [String] = []
        let game = ProcessInfo.processInfo.environment["IDECK_COMPAT_GAME"]
        let learnedProfile = game.flatMap { GameCompatibility.profile($0) }
        // More RAM for the JIT: with plenty of memory left and the extended guest
        // window, ask for a bigger pool. The allocator (ml1036 hole census) shrinks
        // it to the largest hole that fits, so this never asks for more than exists.
        let freeMiB = Int(os_proc_available_memory() >> 20)
        let cleanHistory = (learnedProfile?.consecutiveCrashes ?? 0) == 0
            && (learnedProfile.map { $0.lastGoodPoolMiB < 256 || $0.lastGoodPoolMiB >= base } ?? true)
        if AddressSpaceCheck.hasGuestWindow, cleanHistory, let learnedProfile, learnedProfile.lastGoodPoolMiB > base {
            let grown: Int
            switch freeMiB {
            case 8192...: grown = 896
            case 6144...: grown = 768
            case 5120...: grown = 640
            default: grown = size
            }
            if grown > size {
                size = min(grown, learnedProfile.lastGoodPoolMiB)
                why.append("grown to \(grown) MB (\(freeMiB) MiB free)")
            }
        }
        if let learned = learnedProfile {
            if learned.lastGoodPoolMiB >= 256, learned.lastGoodPoolMiB < min(size, base) {
                size = learned.lastGoodPoolMiB
                why.append("last clean session ran with \(size) MB")
            } else if learned.consecutiveCrashes > 0, learned.lastPoolMiB > 256,
                      let smaller = automaticSteps.first(where: { $0 < learned.lastPoolMiB }) {
                size = min(size, smaller)
                why.append("\(learned.consecutiveCrashes) crash(es) in a row at \(learned.lastPoolMiB) MB")
            }
        }
        // The RW mirror is touched as code is translated: with little memory left a
        // large pool only moves the game closer to iOS's limit.
        let available = freeMiB
        let memoryCap: Int
        switch available {
        case ..<1: memoryCap = size
        case ..<2048: memoryCap = 256
        case ..<3072: memoryCap = 384
        case ..<4096: memoryCap = 512
        default: memoryCap = size
        }
        if memoryCap < size {
            size = memoryCap
            why.append("\(available) MiB available")
        }
        // Without the extended guest window the pool shares the default 64 GB space.
        if !AddressSpaceCheck.hasGuestWindow, size > 384 {
            size = 384
            why.append("no extended address space")
        }
        size = automaticSteps.first(where: { $0 <= size }) ?? 256
        if !why.isEmpty {
            LogStore.shared.log("[jit-pool] automatic size \(size) MB (\(why.joined(separator: ", ")))")
        }
        return size
    }

    /// Runs on a background queue (allocatePool suspends the process for the
    /// debugger's BRK round trips). nil on success, else the reason.
    static func prepare() -> String? {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if ideck_wine_jit_pool_ready() { return nil }
        for key in exports { unsetenv(key) }
        let poolSizeMB = sizeMB
        if let game = ProcessInfo.processInfo.environment["IDECK_COMPAT_GAME"] {
            GameCompatibility.notePool(game, poolMiB: poolSizeMB)
        }
        LogStore.shared.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
        let t0 = CFAbsoluteTimeGetCurrent()
        let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
        LogStore.shared.log("BRK suspension lasted \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s")
        guard let pool else {
            LogStore.shared.log("JIT pool allocation FAILED — not starting Wine.", level: .error)
            return StikJITHelper.poolFailure ?? "The Wine JIT pool could not be allocated."
        }
        LogStore.shared.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
        setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
        setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
        setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
        if let hole = StikJITHelper.poolHole {
            setenv("WINE_IOS_JIT_HOLE", String(format: "%lx:%lx", hole.off, hole.end), 1)
        } else {
            unsetenv("WINE_IOS_JIT_HOLE")
        }
        if let hole2 = StikJITHelper.poolHole2 {
            setenv("WINE_IOS_JIT_HOLE2", String(format: "%lx:%lx", hole2.off, hole2.end), 1)
        } else {
            unsetenv("WINE_IOS_JIT_HOLE2")
        }
        if let low = StikJITHelper.poolLow {
            setenv("WINE_IOS_JIT_TAIL_REGION", String(format: "%lx:%lx", low.rx, low.size), 1)
        } else {
            unsetenv("WINE_IOS_JIT_TAIL_REGION")
        }
        guard ideck_wine_jit_pool_ready() else {
            for key in exports { unsetenv(key) }
            StikJITHelper.discardPool(pool)
            let reason = "The JIT pool failed executable/writable memory validation. Wine was not started. Reconnect StikDebug and try again."
            LogStore.shared.log(reason, level: .error)
            return reason
        }
        // Step 1b (ml524): detach the debugger now, while the VM map is small.
        // StikDebug spends its CPU budget servicing a long session and its
        // departure mid-game stalled or killed the app; detaching here pays that
        // once, before anything is on screen.
        let dt0 = CFAbsoluteTimeGetCurrent()
        StikJITHelper.detachDebugger()
        let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
        LogStore.shared.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms), level: dms > 5000 ? .error : .success)
        return nil
    }
}

/// iDeck: jit-pool.txt, the JIT pool size each game starts with. The list is
/// the repository's jit-pool.txt (top level on GitHub), built into the app; a
/// jit-pool.txt the user puts in Files › On My iPad › iDeck overrides its lines.
///
///     <Steam App ID or .exe name> = <MB>    # comment
///     268910 = 512                          # Cuphead
///
/// The launch names the running game in IDECK_JIT_GAME_STEAM (Steam App ID)
/// and IDECK_JIT_GAME_EXE (program file name).
enum JITPoolList {
    static let fileName = "jit-pool.txt"

    static var bundled: URL? { Bundle.main.url(forResource: "jit-pool", withExtension: "txt") }
    static var userFile: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    /// Nothing is written: the device copy is optional.
    static func ensureFile() {}

    static func parse(_ text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let mb = Int(parts[1]), (256...1152).contains(mb) else { continue }
            result[parts[0].lowercased()] = mb
        }
        return result
    }

    /// key (lowercased App ID or exe name) -> MB: the app's list, then the device's lines.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (stamp: String, list: [String: Int])?

    /// The files are read and parsed once, again only when the device copy changes.
    static func entries() -> [String: Int] {
        let urls = [bundled, userFile].compactMap { $0 }
        let stamp = urls.map { url -> String in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(url.path)@\(date?.timeIntervalSince1970 ?? -1)"
        }.joined(separator: "|")
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached, cached.stamp == stamp { return cached.list }
        var list: [String: Int] = [:]
        for url in urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) { list.merge(parse(text)) { $1 } }
        }
        cached = (stamp, list)
        return list
    }

    static func size(forCurrentGame _: Void) -> Int? {
        let list = entries()
        let env = ProcessInfo.processInfo.environment
        for key in [env["IDECK_JIT_GAME_STEAM"], env["IDECK_JIT_GAME_EXE"]] {
            if let key, !key.isEmpty, let mb = list[key.lowercased()] {
                LogStore.shared.log("[jit-pool-list] \(key): \(mb) MB (jit-pool.txt)")
                return mb
            }
        }
        return nil
    }
}
