import Foundation

/// Swift orchestrates cancellation and result ordering; the repeated pread,
/// SHA-1 and bounded read-window work is owned by SteamNativeCore.c.
enum SteamExistingChunkVerifier {
    struct Entry: Sendable {
        let offset: UInt64
        let length: Int
        let sha: Data
    }

    static let readBlockBytes = 4 * 1024 * 1024

    static func verify(path: String, entries: [Entry]) throws -> [Bool] {
        var results = [Bool](repeating: false, count: entries.count)
        guard !entries.isEmpty else { return results }
        guard let reader = path.withCString({ ideck_steam_verifier_open($0) }) else {
            return results
        }
        defer { ideck_steam_verifier_close(reader) }

        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            guard entry.length > 0, entry.sha.count == IDECK_STEAM_SHA1_BYTES,
                  entry.offset <= UInt64(Int64.max),
                  UInt64(entry.length) <= UInt64(Int64.max) - entry.offset else { continue }
            results[index] = entry.sha.withUnsafeBytes { digest in
                ideck_steam_verifier_check(
                    reader, entry.offset, entry.length,
                    digest.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return results
    }
}
