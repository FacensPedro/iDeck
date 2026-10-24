import Foundation

enum IPAArchivePath {
    static func components(_ raw: String) -> [String]? {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count <= 128, parts.first == "Payload" else { return nil }
        var result: [String] = []
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                guard result.count > 2 else { return nil }
                result.removeLast()
                continue
            }
            guard !part.contains(":"), part.utf8.count <= 255 else { return nil }
            result.append(String(part))
        }
        guard result.first == "Payload" else { return nil }
        if result.count == 1 { return result }
        guard result[1].count > 4,
              result[1].lowercased().hasSuffix(".app") else { return nil }
        return result
    }

    static func isDirectory(_ raw: String, unixMode: Int) -> Bool {
        raw.hasSuffix("/") || raw.hasSuffix("\\") ||
        (unixMode & 0xF000) == 0x4000
    }
}
