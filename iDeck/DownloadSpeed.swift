import Foundation

/// iDeck uses bounded, predictable download queues, sized per store.
enum DownloadSpeed {
    /// Parallel Steam chunk requests on the device (a chunk is about 1 MB, so 48 keep
    /// about 48 MB in flight), and the connections one content server may hold. Valve fixes
    /// the chunk size; only their number is iDeck's.
    static let steamChunks = 48
    static let steamConnections = 64

    /// Epic chunks (about 1 MB each) fetched ahead of the writer: at most ~48 MB of
    /// chunks in flight. Epic fixes the chunk size.
    static let epicWindow = 48

    /// EA: files fetched at once, ranges of one large file fetched at once, and the
    /// connections to EA's CDN they share.
    static let eaFiles = 10
    static let eaSegments = 16
    static let eaConnections = 56
    /// Whole-range requests in flight across all files (EARangeGate). Fewer than the
    /// connections, so none waits inside URLSession, where its timeout would run; the
    /// rest of the connections serve the small files' streams. Each holds one 4 MB range
    /// until written: with 8 MB ranges, 20 keep at most 160 MB, only while downloading.
    static let eaRangeRequests = 20

    /// GOG: files fetched at once, and chunks of one file fetched ahead of its writer
    /// (they are written in order). A game that is one large archive used to download
    /// one chunk at a time. Connections cover both.
    /// 8 files × 6 chunks: 48 chunks in flight. GOG fixes the chunk size.
    static let gogFiles = 8
    static let gogChunksPerFile = 6
    static let gogConnections = 64
}

    
/// Estimates remaining transfer time only from measured bytes and throughput.
/// Never presents an invented ETA while preparing, paused, or verifying files.
enum DownloadETA {
    static func seconds(done: UInt64, total: UInt64, bytesPerSecond: Double) -> Int? {
        guard total > 0, done < total, bytesPerSecond.isFinite, bytesPerSecond > 1_024 else { return nil }
        let remaining = Double(total - done) / bytesPerSecond
        guard remaining.isFinite, remaining >= 0, remaining <= 7 * 24 * 3600 else { return nil }
        return max(1, Int(ceil(remaining)))
    }

    static func label(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" }
        return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h"
    }
}

/// Download speed and problems in iDeck's log, which Bugs & logs reads: one line every
/// 15 s per running download (bytes done, total and the speed over those seconds), one
/// when it ends with its average speed, and the reason when it fails.
enum DownloadLog {
    private struct Sample { var name: String; var started: Date; var startBytes: UInt64; var time: Date; var bytes: UInt64 }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var samples: [String: Sample] = [:]  // guarded by lock
    static let interval: TimeInterval = 15

    static func gigabytes(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }

    static func megabytesPerSecond(_ bytes: UInt64, _ seconds: TimeInterval) -> String {
        String(format: "%.1f MB/s", seconds > 0 ? Double(bytes) / 1_000_000 / seconds : 0)
    }

    /// When each download last received data, for the stall check.
    nonisolated(unsafe) private static var lastData: [String: (name: String, bytes: UInt64, time: Date, reported: Bool)] = [:]  // guarded by lock
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?  // guarded by lock
    static let stallSeconds: TimeInterval = 20

    /// Every 10 s: a download with no new data for `stallSeconds` is written to the log
    /// once, and again when data flows again, so "starts, stops, continues" shows when
    /// and for how long.
    private static func startWatchdogLocked() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            let now = Date()
            var lines: [String] = []
            lock.lock()
            for (store, entry) in lastData where !entry.reported && now.timeIntervalSince(entry.time) >= stallSeconds {
                lastData[store]?.reported = true
                lines.append("[download] \(store) \"\(entry.name)\" no data for \(Int(now.timeIntervalSince(entry.time))) s at \(gigabytes(entry.bytes))")
            }
            if lastData.isEmpty { watchdog?.cancel(); watchdog = nil }
            lock.unlock()
            lines.forEach { AppLog.record($0) }
        }
        watchdog = timer
        timer.resume()
    }

    static func progress(store: String, name: String, done: UInt64, total: UInt64, now: Date = Date()) {
        lock.lock()
        var resumed: TimeInterval?
        if let last = lastData[store], last.name == name, done > last.bytes {
            if last.reported { resumed = now.timeIntervalSince(last.time) }
            lastData[store] = (name, done, now, false)
        } else if lastData[store]?.name != name {
            lastData[store] = (name, done, now, false)
        }
        startWatchdogLocked()
        if let resumed {
            lock.unlock()
            AppLog.record("[download] \(store) \"\(name)\" data again after \(Int(resumed)) s without")
            lock.lock()
        }
        guard var sample = samples[store], sample.name == name, done >= sample.bytes else {
            samples[store] = Sample(name: name, started: now, startBytes: done, time: now, bytes: done)
            lock.unlock()
            return
        }
        let seconds = now.timeIntervalSince(sample.time)
        guard seconds >= interval else { lock.unlock(); return }
        let speed = megabytesPerSecond(done - sample.bytes, seconds)
        sample.time = now
        sample.bytes = done
        samples[store] = sample
        lock.unlock()
        AppLog.record("[download] \(store) \"\(name)\" \(gigabytes(done)) of \(gigabytes(total)), \(speed)")
    }

    static func ended(store: String, name: String, outcome: String, now: Date = Date()) {
        lock.lock()
        let sample = samples.removeValue(forKey: store)
        lastData.removeValue(forKey: store)
        lock.unlock()
        var line = "[download] \(store) \"\(name)\" \(outcome)"
        if let sample, sample.name == name {
            let seconds = now.timeIntervalSince(sample.started)
            line += ", \(gigabytes(sample.bytes - sample.startBytes)) in \(Int(seconds)) s, average \(megabytesPerSecond(sample.bytes - sample.startBytes, seconds))"
        }
        AppLog.record(line)
    }
}
