import Foundation

/// iDeck uses bounded, predictable download queues, sized per store.
enum DownloadSpeed {
    /// Parallel Steam chunk requests on the device.
    static let steamChunks = 8

    /// Epic chunks (about 1 MB each) fetched ahead of the writer. 8 left most of a
    /// fast connection idle; 24 keeps at most ~24 MB of chunks in flight.
    static let epicWindow = 24

    /// EA: files fetched at once, ranges of one large file fetched at once, and the
    /// connections to EA's CDN they share.
    static let eaFiles = 8
    static let eaSegments = 12
    static let eaConnections = 32
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
