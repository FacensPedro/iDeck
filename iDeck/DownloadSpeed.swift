import Foundation

/// iDeck uses a bounded, predictable download queue. Download acceleration
/// and server prioritization are managed by the separately installed iRelay.
enum DownloadSpeed {
    /// Parallel Steam chunk requests on the device.
    static let steamChunks = 8

    /// Epic chunks fetched ahead of the writer.
    static let epicWindow = 8
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
