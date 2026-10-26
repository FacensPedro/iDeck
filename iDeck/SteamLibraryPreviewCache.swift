import Foundation
import CryptoKit

struct SteamLibraryCachedGame: Codable, Sendable, Equatable {
    let appID: UInt32
    let name: String
    let type: String
    let installDir: String
    let oslist: String
    let buildID: UInt32
    let libraryCapsule: String?
    let libraryHero: String?
    let headerImage: String?
    let parentID: UInt32?
}

/// An account-scoped, presentation-only snapshot. This never stores Steam
/// credentials, depot access keys, manifests or launch authorization.
/// Install/download operations must still consult fresh Steam PICS metadata.
enum SteamLibraryPreviewCache {
    private struct Snapshot: Codable {
        let schema: Int
        let savedAt: Date
        let games: [SteamLibraryCachedGame]
    }

    private static let schema = 1
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private static let maximumBytes = 4 * 1024 * 1024
    private static let maximumGames = 20_000

    private static func fileURL(account: String, directory: URL?) -> URL? {
        guard !account.isEmpty else { return nil }
        guard let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let digest = SHA256.hash(data: Data(account.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("iDeckSteamLibrary", isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }

    static func load(account: String, directory: URL? = nil, now: Date = Date()) -> [SteamLibraryCachedGame]? {
        guard let path = fileURL(account: account, directory: directory),
              let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes,
              let data = try? Data(contentsOf: path),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schema == schema,
              snapshot.savedAt <= now,
              now.timeIntervalSince(snapshot.savedAt) <= maxAge,
              !snapshot.games.isEmpty, snapshot.games.count <= maximumGames
        else { return nil }
        return snapshot.games
    }

    @discardableResult
    static func save(account: String, games: [SteamLibraryCachedGame],
                     directory: URL? = nil, now: Date = Date()) -> Bool {
        guard let path = fileURL(account: account, directory: directory),
              !games.isEmpty, games.count <= maximumGames,
              let data = try? JSONEncoder().encode(
                Snapshot(schema: schema, savedAt: now, games: games)),
              data.count <= maximumBytes else { return false }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove(account: String, directory: URL? = nil) {
        guard let path = fileURL(account: account, directory: directory) else { return }
        try? FileManager.default.removeItem(at: path)
    }
}
