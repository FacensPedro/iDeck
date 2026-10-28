import Foundation
import CommonCrypto

@main
struct SteamExistingChunkVerifierTests {
    static func digest(_ data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA1(raw.baseAddress, CC_LONG(raw.count), &result)
        }
        return Data(result)
    }

    static func main() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ideck-steam-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }

        var bytes = Data(repeating: 0, count: 20 * 1024 * 1024)
        let one = Data(repeating: 0x45, count: 1 * 1024 * 1024)
        let two = Data(repeating: 0x6F, count: 2 * 1024 * 1024)
        bytes.replaceSubrange(0..<one.count, with: one)
        bytes.replaceSubrange((16 * 1024 * 1024)..<(18 * 1024 * 1024), with: two)
        try bytes.write(to: path)

        let existing = [
            SteamExistingChunkVerifier.Entry(offset: 0, length: one.count, sha: digest(one)),
            SteamExistingChunkVerifier.Entry(offset: 16 * 1024 * 1024,
                                             length: two.count, sha: digest(two)),
            SteamExistingChunkVerifier.Entry(offset: 18 * 1024 * 1024,
                                             length: 4 * 1024 * 1024, sha: Data(repeating: 0, count: 20)),
            SteamExistingChunkVerifier.Entry(offset: 0, length: one.count,
                                             sha: Data(repeating: 0xFF, count: 20)),
            SteamExistingChunkVerifier.Entry(offset: UInt64.max, length: one.count, sha: digest(one)),
            SteamExistingChunkVerifier.Entry(offset: 0, length: 0, sha: digest(one))
        ]
        let matches = try SteamExistingChunkVerifier.verify(path: path.path, entries: existing)
        assert(matches == [true, true, false, false, false, false], "\(matches)")
        let absent = try SteamExistingChunkVerifier.verify(path: path.path + "-missing", entries: existing)
        assert(absent == Array(repeating: false, count: existing.count))

        bytes[3] = 0xFE
        try bytes.write(to: path)
        let changed = try SteamExistingChunkVerifier.verify(path: path.path, entries: existing)
        assert(changed[0] == false && changed[1] == true)

        let empty = try SteamExistingChunkVerifier.verify(path: path.path, entries: [])
        assert(empty.isEmpty)
        print("PASS: sequential Steam chunk reuse, corruption rejection, truncation, bounds and missing files")
    }
}
