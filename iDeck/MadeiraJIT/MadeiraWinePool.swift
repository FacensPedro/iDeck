import Foundation

/// Madeira's launch steps for the Wine JIT pool (ContentView, "Step 1" and
/// "Step 1b"), line for line: the pool size (896 MB, or madeira.cfg pool),
/// StikJITHelper.allocatePool, the WINE_IOS_JIT_* exports, and the early detach
/// of the debugger right after, while the VM map is still small.
enum MadeiraWinePool {
    /// 896 MB as Madeira; madeira.cfg `pool` (256 to 1152) wins, then iDeck's
    /// Settings choice.
    static var sizeMB: Int {
        if let txt = MadeiraConfig.gameValue("pool") ?? MadeiraConfig.get("pool"),
           let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)), mb >= 256, mb <= 1152 {
            return mb
        }
        // iDeck: the game's line in Documents/jit-pool.txt (JITPoolList).
        if let mb = JITPoolList.size(forCurrentGame: ()) { return mb }
        let chosen = UserDefaults.standard.integer(forKey: "wineJITPoolMiB")
        return (256...1152).contains(chosen) ? chosen : 896
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

/// iDeck: Documents/jit-pool.txt, a list anyone can edit in the Files app
/// (On My iPad › iDeck): the JIT pool size each game starts with.
///
///     # Steam App ID or the game's .exe name = size in MB (256 to 1152)
///     268910 = 512    # Cuphead
///
/// The launch names the running game in IDECK_JIT_GAME_STEAM (Steam App ID)
/// and IDECK_JIT_GAME_EXE (program file name); the first matching line wins.
enum JITPoolList {
    static let fileName = "jit-pool.txt"
    static let defaultText = """
    # iDeck JIT pool list
    # The JIT pool memory each game starts with, in MB (256 to 1152).
    # One game per line: its Steam App ID or its .exe name, "=", the size.
    # Anything after # is a comment. Changes apply at the next game start.
    #
    268910 = 512    # Cuphead

    """

    static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    /// Writes the list with its built-in entries the first time.
    static func ensureFile() {
        guard let url, !FileManager.default.fileExists(atPath: url.path) else { return }
        try? defaultText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// key (lowercased App ID or exe name) -> MB.
    static func entries() -> [String: Int] {
        ensureFile()
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: Int] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let mb = Int(parts[1]), (256...1152).contains(mb) else { continue }
            result[parts[0].lowercased()] = mb
        }
        return result
    }

    static func size(forCurrentGame _: Void) -> Int? {
        let list = entries()
        let env = ProcessInfo.processInfo.environment
        for key in [env["IDECK_JIT_GAME_STEAM"], env["IDECK_JIT_GAME_EXE"]] {
            if let key, !key.isEmpty, let mb = list[key.lowercased()] {
                LogStore.shared.log("[jit-pool-list] \(key): \(mb) MB (Documents/\(fileName))")
                return mb
            }
        }
        return nil
    }
}
