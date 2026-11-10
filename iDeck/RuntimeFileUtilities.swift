import CryptoKit
import Foundation

/// Hash files without loading a complete runtime archive into memory.
enum FileChecksum {
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Lexical conversion within an explicit drive. Keep Wine-visible symlink names.
enum WindowsDrivePath {
    static func relative(_ file: URL, drive: URL) -> String? {
        let root = drive.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return "C:\\" + path.dropFirst(root.count + 1).replacingOccurrences(of: "/", with: "\\")
    }
}
