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
