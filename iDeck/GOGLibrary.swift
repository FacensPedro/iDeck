import Foundation
import Security
import SwiftUI

// GOG integration: sign-in, the GOG Galaxy library, Galaxy installs and the games
// installed in the Wine prefix.
//
// GOG has no public store API; these are the endpoints GOG Galaxy itself uses
// (documented at https://gogapidocs.readthedocs.io and used by Heroic, Lutris
// and gogdl). Sign-in happens on GOG's own page in Safari: iDeck never
// sees the password, only the OAuth code GOG redirects to, and keeps the
// resulting tokens in this device's Keychain.

// MARK: - Tokens

struct GOGTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var userID: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

enum GOGTokenStore {
    private static let service = "ideck.gog.tokens"
    private static let account = "gog_tokens"

    static func load() -> GOGTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GOGTokens.self, from: data)
    }

    static func save(_ tokens: GOGTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { AppLog.record("[gog] Keychain save failed: \(status)") }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - API

enum GOGError: LocalizedError {
    case notSignedIn
    case signInRejected
    case http(Int)
    case invalidResponse
    case noGalaxyBuild

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to GOG first."
        case .signInRejected: return "GOG did not accept the sign-in. Try again."
        case .http(let code): return "GOG returned HTTP \(code). Try again later."
        case .invalidResponse: return "GOG sent an unexpected response."
        case .noGalaxyBuild: return "GOG Galaxy has no Windows build of this game."
        }
    }
}

struct GOGGame: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    /// Protocol-relative image base ("//images-4.gog-statics.com/<hash>").
    let image: String?
    let worksOnWindows: Bool

    /// Portrait cover first (the library cards are 2:3), then GOG's tiles.
    var artworkCandidates: [URL] {
        guard let image, !image.isEmpty else { return [] }
        let base = image.hasPrefix("//") ? "https:" + image : image
        return ["_glx_vertical_cover.webp", "_392.jpg", ".jpg"].compactMap { URL(string: base + $0) }
    }
}

enum GOGAPI {
    static let clientID = "46899977096215655"
    /// GOG Galaxy's published client secret (it is embedded in every Galaxy client).
    static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"
    /// What GOG Galaxy itself sends; the Galaxy service (GOGGalaxy) uses it too.
    static let userAgent = "GOGGalaxyClient/2.0.67.2 (Windows_32bit)"

    static var loginURL: URL {
        var components = URLComponents(string: "https://auth.gog.com/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: "client2"),
        ]
        return components.url!
    }

    /// The OAuth code in GOG's post-login redirect, if `url` is that redirect.
    static func loginCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "embed.gog.com", components.path == "/on_login_success" else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = DownloadSpeed.gogConnections
        // Game chunks are written to disk by the installer: nothing is kept in
        // URLCache (memory, or its Cache.db on disk) for them.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func exchange(code: String) async throws -> GOGTokens {
        try await token([
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ])
    }

    static func refresh(_ tokens: GOGTokens) async throws -> GOGTokens {
        try await token([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken),
        ])
    }

    private static func token(_ items: [URLQueryItem]) async throws -> GOGTokens {
        var components = URLComponents(string: "https://auth.gog.com/token")!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                                 URLQueryItem(name: "client_secret", value: clientSecret)] + items
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 400 || status == 401 ? GOGError.signInRejected : GOGError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { throw GOGError.invalidResponse }
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        let user = (json["user_id"] as? String) ?? (json["user_id"] as? Int).map(String.init) ?? ""
        return GOGTokens(accessToken: access, refreshToken: refresh, userID: user,
                         expiresAt: Date().addingTimeInterval(lifetime))
    }

    /// GET with the bearer token; `url` may be relative to embed.gog.com.
    static func fetchJSON(_ path: String, tokens: GOGTokens) async throws -> Any {
        let url = path.hasPrefix("http") ? URL(string: path)! : URL(string: "https://embed.gog.com" + path)!
        var request = URLRequest(url: url)
        request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 401 ? GOGError.notSignedIn : GOGError.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Every owned game, from GOG Galaxy's own library (galaxy-library.gog.com,
    /// the list GOG Galaxy shows), with titles and artwork from api.gog.com.
    static func ownedGames(tokens: GOGTokens) async throws -> [GOGGame] {
        guard !tokens.userID.isEmpty else { throw GOGError.notSignedIn }
        var ids: [Int] = []
        var seen = Set<Int>()
        var pageToken: String?
        var pages = 0
        repeat {
            var components = URLComponents(string: "https://galaxy-library.gog.com/users/\(tokens.userID)/releases")!
            if let pageToken { components.queryItems = [URLQueryItem(name: "page_token", value: pageToken)] }
            guard let json = try await fetchJSON(components.url!.absoluteString, tokens: tokens) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { throw GOGError.invalidResponse }
            for item in items where (item["platform_id"] as? String) == "gog" {
                let raw = item["external_id"]
                guard let id = (raw as? Int) ?? (raw as? String).flatMap(Int.init), seen.insert(id).inserted else { continue }
                ids.append(id)
            }
            pageToken = json["next_page_token"] as? String
            pages += 1
        } while pageToken?.isEmpty == false && pages < 200
        var games: [GOGGame] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = ids[start..<min(start + 50, ids.count)]
            let path = "https://api.gog.com/products?ids=" + batch.map(String.init).joined(separator: ",")
            guard let products = try await fetchJSON(path, tokens: tokens) as? [[String: Any]] else { throw GOGError.invalidResponse }
            for product in products {
                guard let id = product["id"] as? Int, let title = product["title"] as? String else { continue }
                if let type = product["game_type"] as? String, type != "game" { continue }
                let images = product["images"] as? [String: Any]
                let compatibility = product["content_system_compatibility"] as? [String: Any]
                games.append(GOGGame(id: id, title: title,
                                     image: imageBase((images?["logo2x"] ?? images?["logo"] ?? images?["background"]) as? String),
                                     worksOnWindows: (compatibility?["windows"] as? Bool) ?? true))
            }
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// "//images-4.gog-statics.com/<hash>_glx_logo.jpg" -> "//images-4.gog-statics.com/<hash>".
    static func imageBase(_ url: String?) -> String? {
        guard let url, let slash = url.lastIndex(of: "/") else { return nil }
        let name = url[url.index(after: slash)...]
        let hash = name.prefix { $0.isHexDigit }
        guard hash.count >= 32 else { return nil }
        return String(url[...slash]) + hash
    }

    static func username(tokens: GOGTokens) async -> String? {
        (try? await fetchJSON("/userData.json", tokens: tokens) as? [String: Any])?["username"] as? String
    }

}

// MARK: - Installed games

/// A game a GOG installer put in the prefix. Every GOG installer writes
/// goggame-<id>.info next to the game, naming the executable to start.
struct GOGInstalledGame: Hashable {
    let gameID: Int
    let name: String
    let executable: URL
    let arguments: String
    var isRoot = true
}

enum GOGInstallScanner {
    static func installed(in drive: URL) -> [Int: GOGInstalledGame] {
        let manager = FileManager.default
        var result: [Int: GOGInstalledGame] = [:]
        var roots = ["GOG Games", "Games", "Program Files/GOG Galaxy/Games", "Program Files (x86)/GOG Galaxy/Games",
                     "Program Files/GOG.com", "Program Files (x86)/GOG.com", "Program Files", "Program Files (x86)"]
        // Folders on external drives (ExternalDrives links them under C:\External).
        if let drives = try? manager.contentsOfDirectory(atPath: drive.appendingPathComponent("External").path) {
            roots += drives.map { "External/\($0)/GOG Games" }
        }
        for root in roots {
            let base = drive.appendingPathComponent(root, isDirectory: true)
            guard let folders = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for folder in folders.prefix(500) {
                guard let files = try? manager.contentsOfDirectory(atPath: folder.path) else { continue }
                let infos = files.filter { file in file.hasPrefix("goggame-") && file.hasSuffix(".info") }
                // DLCs add their own info files next to the game's; the game's
                // own file is the one whose gameId equals its rootGameId.
                let parsed = infos.compactMap { parse(folder.appendingPathComponent($0), folder: folder) }
                if let game = parsed.first(where: { $0.isRoot }) ?? parsed.first {
                    result[game.gameID] = game
                }
            }
        }
        return result
    }

    static func parse(_ info: URL, folder: URL) -> GOGInstalledGame? {
        guard let data = try? Data(contentsOf: info), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let idValue = json["gameId"] as? String ?? (json["gameId"] as? Int).map(String.init)
        guard let idValue, let gameID = Int(idValue) else { return nil }
        let tasks = (json["playTasks"] as? [[String: Any]]) ?? []
        guard let task = tasks.first(where: { ($0["isPrimary"] as? Bool) == true && ($0["type"] as? String) != "URLTask" })
                ?? tasks.first(where: { $0["path"] is String }),
              let relative = (task["path"] as? String)?.replacingOccurrences(of: "\\", with: "/"),
              !relative.contains("..") else { return nil }
        var executable = folder.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: executable.path),
           let resolved = SteamInstallFiles.resolveLaunchPath(relative, root: folder, executable: true) {
            // Windows paths are case-insensitive; the files on APFS may differ in case.
            executable = resolved
        }
        guard executable.pathExtension.lowercased() == "exe",
              FileManager.default.fileExists(atPath: executable.path) else { return nil }
        let rootValue = json["rootGameId"] as? String ?? (json["rootGameId"] as? Int).map(String.init)
        return GOGInstalledGame(gameID: gameID, name: json["name"] as? String ?? folder.lastPathComponent,
                                executable: executable, arguments: task["arguments"] as? String ?? "",
                                isRoot: rootValue == nil || rootValue == idValue)
    }
}

// MARK: - Model

/// Bytes downloaded so far, shared by the parallel file downloads.
final class GOGByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ bytes: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        total += bytes
        return total
    }
}

// MARK: - Sign-in

// MARK: - Store

enum GameStore { case steam, gog, epic, ea, ubisoft }
