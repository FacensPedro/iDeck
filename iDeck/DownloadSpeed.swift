import Foundation

/// iDeck uses a bounded, predictable download queue. Download acceleration
/// and server prioritization are managed by the separately installed iRelay.
enum DownloadSpeed {
    /// Parallel Steam chunk requests on the device.
    static let steamChunks = 8

    /// Epic chunks fetched ahead of the writer.
    static let epicWindow = 8
}
