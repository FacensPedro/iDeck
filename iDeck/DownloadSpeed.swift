import Foundation

/// Settings › Downloads › "Unlimited download speed". Off by default: game
/// downloads use a moderate number of parallel connections, leaving
/// bandwidth for the rest of the device. On: as many as the device can
/// handle while it stays cool.
enum DownloadSpeed {
    static let key = "downloads.unlimitedSpeed"

    static var isUnlimited: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Parallel Steam chunk requests when the device is cool.
    static var steamChunks: Int { isUnlimited ? 64 : 8 }
    /// Epic chunks fetched ahead of the writer.
    static var epicWindow: Int { isUnlimited ? 48 : 8 }
}
