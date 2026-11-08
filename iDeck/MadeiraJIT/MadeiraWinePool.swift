import Foundation

/// Madeira's launch steps for the Wine JIT pool (ContentView, "Step 1" and
/// "Step 1b"), line for line: the pool size (896 MB, or madeira.cfg pool),
/// StikJITHelper.allocatePool, the WINE_IOS_JIT_* exports, and the early detach
/// of the debugger right after, while the VM map is still small.
enum MadeiraWinePool {
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
        return (256...1152).contains(chosen) ? chosen : 560
    }

    /// Runs on a background queue (allocatePool suspends the process for the
    /// debugger's BRK round trips). nil on success, else the reason.
    static func prepare() -> String? {
        if ideck_wine_jit_pool_ready() { return nil }
        let poolSizeMB = sizeMB
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
    static func entries() -> [String: Int] {
        var list: [String: Int] = [:]
        for url in [bundled, userFile].compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) { list.merge(parse(text)) { $1 } }
        }
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
