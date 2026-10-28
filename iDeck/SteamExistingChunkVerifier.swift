import Foundation
import CommonCrypto
import Darwin

enum SteamExistingChunkVerifier {
    struct Entry: Sendable {
        let offset: UInt64
        let length: Int
        let sha: Data
    }

    static let readBlockBytes = 16 * 1024 * 1024

    static func verify(path: String, entries: [Entry]) throws -> [Bool] {
        var results = [Bool](repeating: false, count: entries.count)
        guard !entries.isEmpty else { return results }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return results }
        defer { close(fd) }

        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 1)
        var buffer = [UInt8](repeating: 0, count: readBlockBytes)
        var blockOffset: UInt64 = 0
        var available = 0
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            guard entry.sha.count == digest.count,
                  entry.length > 0, entry.length <= readBlockBytes,
                  entry.offset <= UInt64(Int64.max) - UInt64(entry.length) else { continue }

            let end = entry.offset + UInt64(entry.length)
            if entry.offset < blockOffset || end > blockOffset + UInt64(available) {
                blockOffset = entry.offset
                available = buffer.withUnsafeMutableBytes { bytes in
                    let count = pread(fd, bytes.baseAddress, readBlockBytes, off_t(entry.offset))
                    return max(0, count)
                }
                if available < entry.length { continue }
            }

            let start = Int(entry.offset - blockOffset)
            buffer.withUnsafeBytes { bytes in
                _ = CC_SHA1(bytes.baseAddress! + start, CC_LONG(entry.length), &digest)
            }
            results[index] = Data(digest) == entry.sha
        }
        return results
    }
}
