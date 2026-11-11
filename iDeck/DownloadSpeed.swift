import Foundation

/// iDeck uses bounded, predictable download queues, sized per store.
enum DownloadSpeed {
    /// Parallel Steam chunk requests on the device, and the connections one content
    /// server may hold. 8 left a fast connection half idle; a chunk is about 1 MB.
    static let steamChunks = 16

    /// Epic chunks (about 1 MB each) fetched ahead of the writer: at most ~32 MB of
    /// chunks in flight.
    static let epicWindow = 32

    /// EA: files fetched at once, ranges of one large file fetched at once, and the
    /// connections to EA's CDN they share.
    static let eaFiles = 8
    static let eaSegments = 16
    static let eaConnections = 40

    /// GOG: files fetched at once, and chunks of one file fetched ahead of its writer
    /// (they are written in order). A game that is one large archive used to download
    /// one chunk at a time. Connections cover both.
    static let gogFiles = 4
    static let gogChunksPerFile = 3
    static let gogConnections = 12
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
