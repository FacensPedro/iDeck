import Foundation
import Security
import SwiftUI
import WebKit

// GOG integration: sign-in, the GOG Galaxy library, Galaxy installs and the games
// installed in the Wine prefix.
//
// GOG has no public store API; these are the endpoints GOG Galaxy itself uses
// (documented at https://gogapidocs.readthedocs.io and used by Heroic, Lutris
// and gogdl). Sign-in happens on GOG's own page in a web view: iDeck never
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

@MainActor
final class GOGLibraryModel: ObservableObject {
    static let shared = GOGLibraryModel()

    @Published private(set) var isSignedIn = GOGTokenStore.load() != nil
    @Published private(set) var username: String?
    @Published private(set) var games: [GOGGame] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installed: [Int: GOGInstalledGame] = [:]
    @Published private(set) var downloadProgress: [Int: Double] = [:]
    @Published private(set) var downloadErrors: [Int: String] = [:]
    @Published private(set) var downloadETASeconds: [Int: Int] = [:]
    /// Bytes downloaded and to download for each game being installed (the details page).
    @Published private(set) var downloadedBytes: [Int: (done: UInt64, total: UInt64)] = [:]
    private var transferRateSamples: [Int: (at: Date, bytes: UInt64, rate: Double)] = [:]

    private func updateDownloadETA(gameID: Int, done: UInt64, total: UInt64) {
        guard total > 0, done < total else {
            downloadETASeconds.removeValue(forKey: gameID)
            return
        }
        let now = Date()
        guard let previous = transferRateSamples[gameID] else {
            transferRateSamples[gameID] = (now, done, 0)
            return
        }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed >= 1.0 else { return }
        let currentRate = done > previous.bytes ? Double(done - previous.bytes) / elapsed : 0
        let smoothed = previous.rate > 0 && currentRate > 0
            ? 0.65 * previous.rate + 0.35 * currentRate : currentRate
        transferRateSamples[gameID] = (now, done, smoothed)
        downloadETASeconds[gameID] = DownloadETA.seconds(done: done, total: total,
                                                         bytesPerSecond: smoothed)
    }

    private func resetDownloadETA(gameID: Int) {
        downloadedBytes.removeValue(forKey: gameID)
        transferRateSamples.removeValue(forKey: gameID)
        downloadETASeconds.removeValue(forKey: gameID)
    }

    @Published private(set) var pausedDownloads: Set<Int> = []
    /// Install size of each game's Galaxy build, from GOG; 0 = unknown.
    @Published private(set) var downloadSizes: [Int: Int64] = [:]
    /// Size on disk of installed games, measured from their install folder.
    @Published private(set) var installedSizes: [Int: Int64] = [:]

    /// Fetches the Galaxy build size for the game details page (once).
    func loadSize(for game: GOGGame) async {
        if let folder = installed[game.id]?.executable.deletingLastPathComponent(), installedSizes[game.id] == nil {
            let root = Self.installFolder(containing: folder)
            let bytes = await Task.detached(priority: .utility) { Self.folderSize(root) }.value
            if bytes > 0 { installedSizes[game.id] = bytes }
        }
        guard downloadSizes[game.id] == nil, let tokens = try? await tokens() else { return }
        if let plan = try? await GOGContentSystem.plan(gameID: game.id, tokens: tokens) {
            downloadSizes[game.id] = plan.installBytes
        }
    }

    enum InstallOutcome {
        /// The game's files are in C:\GOG Games\<folder>.
        case installed
        case failed
    }

    /// Installs a game the way GOG Galaxy does: every file of the newest
    /// Windows build is downloaded from GOG's content system straight into
    /// C:\GOG Games\<installDirectory>. Nothing runs in Wine. Only GOG
    /// Galaxy builds are installed; no offline installer is used.
    func install(_ game: GOGGame, prefixPath: URL, completion: @escaping (InstallOutcome) -> Void) {
        guard downloadTasks[game.id] == nil else { return }
        pausedDownloads.remove(game.id)
        resumeDownloads[game.id] = { [weak self] in self?.install(game, prefixPath: prefixPath, completion: completion) }
        downloadErrors[game.id] = nil
        downloadProgress[game.id] = 0
        resetDownloadETA(gameID: game.id)
        let games = prefixPath.appendingPathComponent("drive_c/GOG Games", isDirectory: true)
        BackgroundDownloads.gog.attach(active: { [weak self] in !(self?.downloadTasks.isEmpty ?? true) },
                                       pause: {}, resume: {})
        BackgroundDownloads.gog.started(name: game.title)
        downloadTasks[game.id] = Task {
            var outcome = BackgroundDownloads.Outcome.paused
            defer {
                resetDownloadETA(gameID: game.id)
                downloadTasks[game.id] = nil
                if !pausedDownloads.contains(game.id) { downloadProgress[game.id] = nil }
                BackgroundDownloads.gog.ended(name: game.title, outcome: outcome, queueEmpty: downloadTasks.isEmpty)
                if !pausedDownloads.contains(game.id) { resumeDownloads.removeValue(forKey: game.id) }
            }
            do {
                let tokens = try await tokens()
                let plan: GOGContentPlan
                do {
                    plan = try await GOGContentSystem.plan(gameID: game.id, tokens: tokens)
                } catch GOGContentError.noBuild {
                    throw GOGError.noGalaxyBuild
                }
                let name = GOGContentSystem.safePath(plan.installDirectory)?.replacingOccurrences(of: "/", with: " ")
                    ?? "Game \(game.id)"
                let staging = games.appendingPathComponent(".downloading/\(name)", isDirectory: true)
                stagingFolders[game.id] = staging
                let final = games.appendingPathComponent(name, isDirectory: true)
                let total = max(plan.downloadBytes, 1)
                downloadSizes[game.id] = plan.installBytes
                let counter = GOGByteCounter()
                AppLog.record("[gog] installing game \(game.id): \(plan.files.count) files, \(plan.downloadBytes) bytes to download")
                let installer = GOGContentInstaller(tokens: tokens) { bytes in
                    let done = counter.add(bytes)
                    Task { @MainActor in
                        self.downloadProgress[game.id] = min(Double(done) / Double(total), 1)
                        self.downloadedBytes[game.id] = (UInt64(max(done, 0)), UInt64(total))
                        self.updateDownloadETA(gameID: game.id, done: UInt64(max(done, 0)), total: UInt64(total))
                        BackgroundDownloads.gog.progress(done: UInt64(done), total: UInt64(total))
                    }
                }
                try await installer.install(plan, into: staging)
                let manager = FileManager.default
                if manager.fileExists(atPath: final.path) {
                    // Merge into an existing folder (an update or an earlier installer).
                    let walker = manager.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])
                    while let item = walker?.nextObject() as? URL {
                        guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                        let relative = String(item.standardizedFileURL.path.dropFirst(staging.standardizedFileURL.path.count + 1))
                        let target = final.appendingPathComponent(relative)
                        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? manager.removeItem(at: target)
                        try manager.moveItem(at: item, to: target)
                    }
                    try? manager.removeItem(at: staging)
                } else {
                    try manager.moveItem(at: staging, to: final)
                }
                // Install script and redistributables, used before each start (GOGLaunchServices).
                GOGLaunchServices.record(plan, folder: final)
                AppLog.record("[gog] game \(game.id) installed into C:\\GOG Games\\\(name)")
                outcome = .completed
                refreshInstalled(prefixPath: prefixPath)
                completion(.installed)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    completion(.failed)
                } else {
                    downloadErrors[game.id] = error.localizedDescription
                    outcome = .failed(error.localizedDescription)
                    AppLog.record("[gog] install failed for game \(game.id): \(error.localizedDescription)")
                    completion(.failed)
                }
            }
        }
    }

    /// The game's own folder: the highest folder up from the program that
    /// still holds a goggame-*.info file, otherwise the program's folder.
    nonisolated static func installFolder(containing folder: URL) -> URL {
        var best = folder
        var current = folder
        for _ in 0..<4 {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            if names.contains(where: { $0.hasPrefix("goggame-") && $0.hasSuffix(".info") }) { best = current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return best
    }

    nonisolated static func folderSize(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    private var downloadTasks: [Int: Task<Void, Never>] = [:]
    private var resumeDownloads: [Int: () -> Void] = [:]
    private var stagingFolders: [Int: URL] = [:]
    private var cancellationCleanup: [Int: Task<Void, Never>] = [:]
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iDeck-gog-library.json")

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([GOGGame].self, from: data) {
            games = cached
        }
    }

    /// A valid access token, refreshed when it has expired.
    func tokens() async throws -> GOGTokens {
        guard let stored = GOGTokenStore.load() else {
            isSignedIn = false
            throw GOGError.notSignedIn
        }
        guard stored.isExpired else { return stored }
        do {
            let fresh = try await GOGAPI.refresh(stored)
            GOGTokenStore.save(fresh)
            return fresh
        } catch GOGError.signInRejected {
            signOut()
            throw GOGError.notSignedIn
        }
    }

    func completeSignIn(code: String) async throws {
        let tokens = try await GOGAPI.exchange(code: code)
        GOGTokenStore.save(tokens)
        isSignedIn = true
        AppLog.record("[gog] signed in")
        await refresh()
    }

    func signOut() {
        GOGTokenStore.delete()
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        downloadProgress.removeAll()
        isSignedIn = false
        username = nil
        games = []
        try? FileManager.default.removeItem(at: cacheURL)
        AppLog.record("[gog] signed out")
    }

    func refresh() async {
        guard isSignedIn, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let tokens = try await tokens()
            async let owned = GOGAPI.ownedGames(tokens: tokens)
            async let name = GOGAPI.username(tokens: tokens)
            games = try await owned
            username = await name
            if let data = try? JSONEncoder().encode(games) { try? data.write(to: cacheURL, options: .atomic) }
        } catch {
            errorMessage = error.localizedDescription
            AppLog.record("[gog] library refresh failed: \(error.localizedDescription)")
        }
    }

    func refreshInstalled(prefixPath: URL?) {
        guard let prefixPath else { installed = [:]; return }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        Task {
            installed = await Task.detached(priority: .utility) {
                GOGInstallScanner.installed(in: drive)
            }.value
        }
    }

    /// Deletes an installed game's folder (the one holding its goggame-*.info
    /// file) and rescans. Refuses folders that are not inside drive_c.
    @discardableResult
    func uninstall(_ gameID: Int, prefixPath: URL) -> Bool {
        guard let game = installed[gameID] else { return false }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true).standardizedFileURL.path
        let folder = Self.installFolder(containing: game.executable.deletingLastPathComponent()).standardizedFileURL
        guard folder.path.hasPrefix(drive + "/"), folder.pathComponents.count > drive.split(separator: "/").count + 2 else { return false }
        do { try FileManager.default.removeItem(at: folder) } catch { return false }
        installed[gameID] = nil
        installedSizes[gameID] = nil
        refreshInstalled(prefixPath: prefixPath)
        return true
    }

    /// Wide artwork for a game's details page, best first.
    static func bannerCandidates(_ game: GOGGame) -> [URL] {
        guard let image = game.image, !image.isEmpty else { return [] }
        let base = image.hasPrefix("//") ? "https:" + image : image
        return ["_glx_bg_top_padding_7.webp", "_bg_crop_1366x655.jpg", "_product_card_v2_mobile_slider_639.jpg"]
            .compactMap { URL(string: base + $0) }
    }

    /// Pause cancels network activity while retaining GOG's staged files.
    func pauseDownload(_ game: GOGGame) {
        guard let task = downloadTasks[game.id] else { return }
        pausedDownloads.insert(game.id)
        task.cancel()
    }

    func resumeDownload(_ game: GOGGame) {
        guard pausedDownloads.contains(game.id) else { return }
        let previous = downloadTasks[game.id]
        Task { @MainActor in
            await previous?.value
            guard pausedDownloads.contains(game.id) else { return }
            pausedDownloads.remove(game.id)
            resumeDownloads[game.id]?()
        }
    }

    func cancelDownload(_ game: GOGGame) {
        let previous = downloadTasks[game.id]
        previous?.cancel()
        pausedDownloads.remove(game.id)
        resumeDownloads.removeValue(forKey: game.id)
        cancellationCleanup[game.id] = Task { @MainActor in
            await previous?.value
            if let staging = stagingFolders.removeValue(forKey: game.id) {
                try? FileManager.default.removeItem(at: staging)
            }
            downloadProgress.removeValue(forKey: game.id)
            cancellationCleanup.removeValue(forKey: game.id)
        }
    }

    func cancelDownloadAndWait(_ game: GOGGame) async {
        cancelDownload(game)
        let cleanup = cancellationCleanup[game.id]
        await cleanup?.value
    }
}

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

/// GOG's own login page; closes itself once GOG redirects with the code.
struct GOGSignInView: View {
    @ObservedObject var library = GOGLibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isFinishing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ZStack {
                GOGLoginWebView { code in
                    guard !isFinishing else { return }
                    isFinishing = true
                    Task {
                        do {
                            try await library.completeSignIn(code: code)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isFinishing = false
                        }
                    }
                }
                if isFinishing {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    ProgressView(tr("Signing in to GOG...")).tint(.white).foregroundColor(.white)
                }
            }
            .navigationTitle(tr("GOG sign-in"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
            }
            .alert(tr("GOG sign-in"), isPresented: Binding(get: { errorMessage != nil },
                                                           set: { if !$0 { errorMessage = nil } })) {
                Button(tr("OK"), role: .cancel) {}
            } message: {
                Text(tr(errorMessage ?? ""))
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct GOGLoginWebView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    /// Google refuses to sign in inside embedded web views that announce
    /// themselves as such, so the page sees mobile Safari's user agent.
    static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    func makeUIView(context: Context) -> WKWebView {
        // A non-persistent store: GOG's session cookie is not kept by iDeck.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = Self.safariUserAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: GOGAPI.loginURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Handles GOG's redirect and the pop-up windows that "Sign in with
    /// Google / Steam / Discord / Xbox" open. Each pop-up is shown on top of
    /// the login page and shares its session, so the provider can hand the
    /// result back to GOG's page through window.opener.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onCode: (String) -> Void
        private var popups: [WKWebView] = []
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let code = GOGAPI.loginCode(from: url) {
                decisionHandler(.cancel)
                closeAllPopups()
                onCode(code)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // A link with target=_blank: keep it in the same page.
            guard navigationAction.targetFrame == nil else { return nil }
            let host = webView
            let popup = WKWebView(frame: host.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.customUserAgent = GOGLoginWebView.safariUserAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            host.addSubview(popup)
            popups.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard let index = popups.firstIndex(of: webView) else { return }
            popups.remove(at: index)
            webView.removeFromSuperview()
        }

        private func closeAllPopups() {
            popups.forEach { $0.removeFromSuperview() }
            popups.removeAll()
        }
    }
}

// MARK: - Store

enum GameStore { case steam, gog, epic, ea }
