import Foundation
import Security
import SwiftUI
import WebKit

// GOG integration: sign-in, owned library, installer downloads and the games
// those installers put in the Wine prefix.
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
    case noWindowsInstaller

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to GOG first."
        case .signInRejected: return "GOG did not accept the sign-in. Try again."
        case .http(let code): return "GOG returned HTTP \(code). Try again later."
        case .invalidResponse: return "GOG sent an unexpected response."
        case .noWindowsInstaller: return "GOG offers no Windows installer for this game."
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

struct GOGInstallerFile: Hashable {
    let manualURL: String
    let name: String
}

enum GOGAPI {
    static let clientID = "46899977096215655"
    /// GOG Galaxy's published client secret (it is embedded in every Galaxy client).
    static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"

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
        config.httpMaximumConnectionsPerHost = 6
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

    /// Every owned game (all pages of the account's filtered product list).
    static func ownedGames(tokens: GOGTokens) async throws -> [GOGGame] {
        var games: [GOGGame] = []
        var page = 1
        var pages = 1
        repeat {
            guard let json = try await fetchJSON("/account/getFilteredProducts?mediaType=1&sortBy=title&page=\(page)",
                                             tokens: tokens) as? [String: Any],
                  let products = json["products"] as? [[String: Any]] else { throw GOGError.invalidResponse }
            pages = (json["totalPages"] as? Int) ?? 1
            for product in products {
                guard let id = product["id"] as? Int, let title = product["title"] as? String else { continue }
                let worksOn = product["worksOn"] as? [String: Any]
                games.append(GOGGame(id: id, title: title, image: product["image"] as? String,
                                     worksOnWindows: (worksOn?["Windows"] as? Bool) ?? true))
            }
            page += 1
        } while page <= pages && page <= 200
        return games
    }

    static func username(tokens: GOGTokens) async -> String? {
        (try? await fetchJSON("/userData.json", tokens: tokens) as? [String: Any])?["username"] as? String
    }

    /// The Windows offline installer files, in the user's language when GOG
    /// offers it, otherwise English, otherwise the first language listed.
    /// `account/gameDetails` lists downloads as [[language, {windows: [...]}]].
    static func windowsInstaller(gameID: Int, tokens: GOGTokens) async throws -> [GOGInstallerFile] {
        guard let json = try await fetchJSON("/account/gameDetails/\(gameID).json", tokens: tokens) as? [String: Any],
              let downloads = json["downloads"] as? [[Any]] else { throw GOGError.invalidResponse }
        var byLanguage: [(String, [GOGInstallerFile])] = []
        for entry in downloads where entry.count == 2 {
            guard let language = entry[0] as? String,
                  let platforms = entry[1] as? [String: Any],
                  let windows = platforms["windows"] as? [[String: Any]] else { continue }
            let files = windows.compactMap { file -> GOGInstallerFile? in
                guard let manual = file["manualUrl"] as? String else { return nil }
                return GOGInstallerFile(manualURL: manual, name: (file["name"] as? String) ?? "")
            }
            if !files.isEmpty { byLanguage.append((language, files)) }
        }
        let preferred = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
        let chosen = byLanguage.first { $0.0.localizedCaseInsensitiveContains(preferred) }
            ?? byLanguage.first { $0.0.localizedCaseInsensitiveContains("English") }
            ?? byLanguage.first
        guard let files = chosen?.1, !files.isEmpty else { throw GOGError.noWindowsInstaller }
        return files
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

    private var downloadTasks: [Int: Task<Void, Never>] = [:]
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
            removeFinishedInstallers()
        }
    }

    func isDownloading(_ game: GOGGame) -> Bool { downloadTasks[game.id] != nil }

    /// Downloads the Windows offline installer (setup .exe plus any .bin
    /// parts, which must sit next to it) into the prefix's WindowsDownloads
    /// folder, where it shows up as a Windows app to run.
    func downloadInstaller(_ game: GOGGame, prefixPath: URL, completion: @escaping (URL?) -> Void) {
        guard downloadTasks[game.id] == nil else { return }
        downloadErrors[game.id] = nil
        downloadProgress[game.id] = 0
        let folder = prefixPath.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
        BackgroundDownloads.gog.attach(active: { [weak self] in !(self?.downloadTasks.isEmpty ?? true) },
                                       pause: {}, resume: {})
        BackgroundDownloads.gog.started(name: game.title)
        downloadTasks[game.id] = Task {
            var outcome = BackgroundDownloads.Outcome.paused
            defer {
                downloadTasks[game.id] = nil
                downloadProgress[game.id] = nil
                BackgroundDownloads.gog.ended(name: game.title, outcome: outcome, queueEmpty: downloadTasks.isEmpty)
            }
            do {
                let tokens = try await tokens()
                let files = try await GOGAPI.windowsInstaller(gameID: game.id, tokens: tokens)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var setup: URL?
                var saved: [URL] = []
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    let part = try await download(file, into: folder, tokens: tokens) { fraction in
                        let overall = (Double(index) + fraction) / Double(files.count)
                        self.downloadProgress[game.id] = overall
                        BackgroundDownloads.gog.progress(done: UInt64(overall * 10_000), total: 10_000)
                    }
                    saved.append(part)
                    if setup == nil, part.pathExtension.lowercased() == "exe" { setup = part }
                }
                installerFiles[game.id] = saved
                AppLog.record("[gog] installer downloaded for game \(game.id)")
                outcome = .completed
                completion(setup)
            } catch is CancellationError {
                completion(nil)
            } catch {
                downloadErrors[game.id] = error.localizedDescription
                outcome = .failed(error.localizedDescription)
                AppLog.record("[gog] installer download failed for game \(game.id): \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    /// Installer files downloaded per game, removed once the game is installed.
    private var installerFiles: [Int: [URL]] = [:]

    /// The command line that installs a GOG offline installer (Inno Setup)
    /// without any windows, into C:\GOG Games\<title>.
    static func silentInstallArguments(for game: GOGGame) -> String {
        let folder = String(game.title.unicodeScalars.filter {
            !"\\/:*?\"<>|".unicodeScalars.contains($0) && $0.value >= 32
        }.map(Character.init)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let name = folder.isEmpty ? "Game \(game.id)" : folder
        return "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS /DIR=\"C:\\GOG Games\\\(name)\""
    }

    /// After a Wine session: removes the installers of games that are now installed.
    func removeFinishedInstallers() {
        for (id, files) in installerFiles where installed[id] != nil {
            for file in files { try? FileManager.default.removeItem(at: file) }
            installerFiles[id] = nil
            AppLog.record("[gog] game \(id) installed; installer removed")
        }
    }

    func cancelDownload(_ game: GOGGame) {
        downloadTasks[game.id]?.cancel()
    }

    /// `manualUrl` answers with a redirect to a signed CDN URL; URLSession
    /// follows it (the bearer token is not forwarded to the CDN host).
    private func download(_ file: GOGInstallerFile, into folder: URL, tokens: GOGTokens,
                          progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://www.gog.com" + file.manualURL)!)
        request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
        let delegate = GOGDownloadDelegate(progress: progress)
        // Large installers often outlive a Wi-Fi hiccup: resume up to five
        // times from where the connection dropped instead of failing.
        var resumeData: Data?
        var attempt = 0
        var result: (URL, URLResponse)
        while true {
            do {
                if let data = resumeData {
                    result = try await GOGAPI.session.download(resumeFrom: data, delegate: delegate)
                } else {
                    result = try await GOGAPI.session.download(for: request, delegate: delegate)
                }
                break
            } catch let error as URLError where attempt < 5 && [.networkConnectionLost, .timedOut,
                                                                .notConnectedToInternet, .cannotConnectToHost].contains(error.code) {
                attempt += 1
                resumeData = error.downloadTaskResumeData ?? resumeData
                AppLog.record("[gog] download interrupted (\(error.code.rawValue)); retry \(attempt)/5")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        let (temporary, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GOGError.http(status) }
        var name = response.suggestedFilename ?? response.url?.lastPathComponent ?? file.name
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

private final class GOGDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @MainActor (Double) -> Void
    init(progress: @escaping @MainActor (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
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

// MARK: - Store badge

enum GameStore { case steam, gog, epic }

/// A small store mark next to a game's name. When the app bundles official
/// artwork as "StoreBadgeSteam" / "StoreBadgeGOG" / "StoreBadgeEpic" image
/// assets, that is used; otherwise a neutral text tag.
struct StoreBadge: View {
    let store: GameStore

    private var assetName: String {
        switch store {
        case .steam: return "StoreBadgeSteam"
        case .gog: return "StoreBadgeGOG"
        case .epic: return "StoreBadgeEpic"
        }
    }
    private var label: String {
        switch store {
        case .steam: return "Steam"
        case .gog: return "GOG"
        case .epic: return "Epic"
        }
    }
    private var tint: Color {
        switch store {
        case .steam: return Color(red: 0.11, green: 0.24, blue: 0.40)
        case .gog: return Color(red: 0.42, green: 0.16, blue: 0.55)
        case .epic: return Color(red: 0.20, green: 0.20, blue: 0.22)
        }
    }

    var body: some View {
        Group {
            if UIImage(named: assetName) != nil {
                Image(assetName)
                    .renderingMode(store == .epic ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.white)
                    .frame(width: store == .epic ? 15 : 13, height: store == .epic ? 17 : 13)
            } else {
                Text(label)
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(tint, in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .accessibilityLabel(label)
    }
}
