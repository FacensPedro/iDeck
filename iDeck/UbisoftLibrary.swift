import Foundation

/// A Ubisoft game: one Ubisoft Connect installed into the prefix, or one the iDeck
/// account owns (from Ubisoft's account service) that is not installed yet.
struct UbisoftGame: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The game's main program, when installed.
    let executable: URL?
    /// The game's portrait cover (Steam's library art for the same title), once found.
    var coverURL: URL? = nil
}

/// Covers for Ubisoft games. Ubisoft's account service gives only names, so the cover
/// is Steam's 600x900 library art of the game with the same title (most Ubisoft games
/// are also sold on Steam). Answers, including "none", are kept so the search runs once.
enum UbisoftCovers {
    private static let storeKey = "ubisoft.coverAppIDs"

    static func key(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    static func url(appID: Int) -> URL? {
        appID > 0 ? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg") : nil
    }

    /// The cached Steam app id for a title: nil when never searched, 0 when none was found.
    static func cached(_ title: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int])?[key(title)]
    }

    static func coverURL(for title: String) async -> URL? {
        if let known = cached(title) { return url(appID: known) }
        guard let appID = await steamAppID(for: title) else { return nil }
        var store = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int]) ?? [:]
        store[key(title)] = appID
        UserDefaults.standard.set(store, forKey: storeKey)
        return url(appID: appID)
    }

    /// Steam's store search: an exact title match first, then a title that starts with
    /// the Ubisoft name. 0 means Steam answered without a match; nil means no answer.
    private static func steamAppID(for title: String) async -> Int? {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [URLQueryItem(name: "term", value: title),
                                 URLQueryItem(name: "l", value: "english"),
                                 URLQueryItem(name: "cc", value: "US")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items = (root["items"] as? [[String: Any]] ?? []).compactMap { item -> (Int, String)? in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return (id, key(name))
        }
        let wanted = key(title)
        guard !wanted.isEmpty else { return 0 }
        if let exact = items.first(where: { $0.1 == wanted }) { return exact.0 }
        if let close = items.first(where: { $0.1.hasPrefix(wanted) || wanted.hasPrefix($0.1) && $0.1.count >= 6 }) { return close.0 }
        return 0
    }
}

/// Ubisoft Connect's games for the store page, shown once the launcher is installed.
/// Installed games start directly (the game's own program); the launcher is not opened
/// by iDeck, and the iDeck Ubisoft account lists the owned games.
@MainActor
final class UbisoftLibrary: ObservableObject {
    static let shared = UbisoftLibrary()

    @Published private(set) var games: [UbisoftGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?

    func refresh() {
        guard task == nil else { return }
        refreshing = true
        task = Task { [weak self] in
            let drive = MadeiraDock.drive
            let installed = await Task.detached(priority: .utility) { Self.installedGames(drive: drive) }.value
            var owned: [String] = []
            var failure: String?
            if let session = UbisoftSavedSession.load(), !session.expired {
                do { owned = try await Self.ownedTitles(session: session) }
                catch { failure = "Ubisoft: " + tr("Could not load the owned games.") }
            }
            guard let self else { return }
            let names = Set(installed.map { Self.key($0.title) })
            let missing = owned.filter { !names.contains(Self.key($0)) }
                .map { UbisoftGame(id: "owned:" + Self.key($0), title: $0, executable: nil) }
            self.games = (installed + missing).map { game in
                var game = game
                game.coverURL = UbisoftCovers.cached(game.title).flatMap(UbisoftCovers.url(appID:))
                return game
            }
            self.error = failure
            self.refreshing = false
            self.task = nil
            await self.findCovers()
        }
    }

    /// Looks up the covers not cached yet, one title at a time, and shows each as it arrives.
    private func findCovers() async {
        for game in games where game.coverURL == nil && UbisoftCovers.cached(game.title) == nil {
            guard let url = await UbisoftCovers.coverURL(for: game.title) else { continue }
            if let index = games.firstIndex(where: { $0.id == game.id }) { games[index].coverURL = url }
        }
    }

    private static func key(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Installed games

    /// Ubisoft Connect records each game it installs under
    /// HKLM\Software\[Wow6432Node\]Ubisoft\Launcher\Installs\<id> with its InstallDir.
    nonisolated static func installedGames(drive: URL) -> [UbisoftGame] {
        let prefix = drive.deletingLastPathComponent()
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return [] }
        var folders: [String: String] = [:]
        var current: String?
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.lowercased().replacingOccurrences(of: "\\\\", with: "\\")
                current = nil
                for base in ["[software\\wow6432node\\ubisoft\\launcher\\installs\\", "[software\\ubisoft\\launcher\\installs\\"]
                where header.hasPrefix(base) {
                    let rest = header.dropFirst(base.count)
                    if let end = rest.firstIndex(of: "]"), !rest[..<end].contains("\\") { current = String(rest[..<end]) }
                }
                continue
            }
            guard let id = current, line.lowercased().hasPrefix("\"installdir\"=\"") else { continue }
            folders[id] = String(line.dropFirst("\"InstallDir\"=\"".count).dropLast())
                .replacingOccurrences(of: "\\\\", with: "/")
        }
        let shortcuts = WindowsShortcutScanner.programs(in: drive)
        return folders.compactMap { id, path -> UbisoftGame? in
            guard path.lowercased().hasPrefix("c:/") else { return nil }
            let relative = path.dropFirst(3).split(separator: "/").map(String.init)
            guard !relative.contains(".."), !relative.isEmpty else { return nil }
            let folder = relative.reduce(drive) { $0.appendingPathComponent($1, isDirectory: true) }
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            return UbisoftGame(id: id, title: folder.lastPathComponent,
                               executable: mainExecutable(in: folder, shortcuts: shortcuts))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The game's program: a Start Menu or Desktop shortcut into its folder, otherwise
    /// the largest program in it (two levels deep) that is not a setup or helper.
    nonisolated static func mainExecutable(in folder: URL, shortcuts: [URL]) -> URL? {
        let root = folder.standardizedFileURL.path.lowercased() + "/"
        if let linked = shortcuts.first(where: { $0.standardizedFileURL.path.lowercased().hasPrefix(root) }) { return linked }
        let helpers = ["unins", "setup", "crash", "report", "redist", "vcredist", "dxsetup", "dotnet", "anticheat",
                       "easyanticheat", "battleye", "uplay", "upc", "ubisoftconnect", "helper", "cef", "install"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, size: Int)?
        var seen = 0
        while let item = walker.nextObject() as? URL, seen < 5000 {
            seen += 1
            if walker.level > 3 { walker.skipDescendants(); continue }
            let name = item.lastPathComponent.lowercased()
            guard name.hasSuffix(".exe"), !helpers.contains(where: name.contains),
                  let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { continue }
            if size > (best?.size ?? 0) { best = (item, size) }
        }
        return best?.url
    }

    // MARK: Owned games

    /// The titles the account owns, from Ubisoft's GraphQL service with the iDeck session.
    private static func ownedTitles(session: UbisoftSavedSession) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://public-ubiservices.ubi.com/v1/profiles/me/uplay/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(session.appIDUsed ?? UbisoftSavedSession.appIDs[0], forHTTPHeaderField: "Ubi-AppId")
        request.setValue("Ubi_v1 t=" + session.ticket, forHTTPHeaderField: "Authorization")
        if let id = session.sessionID { request.setValue(id, forHTTPHeaderField: "Ubi-SessionId") }
        let query = "query AllGames { viewer { id ownedGames: games(filterBy: {isOwned: true}) "
            + "{ totalCount nodes { id spaceId name } } } }"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["operationName": "AllGames", "query": query])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let viewer = (root?["data"] as? [String: Any])?["viewer"] as? [String: Any]
        let nodes = (viewer?["ownedGames"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        var titles: [String] = []
        for node in nodes {
            if let name = node["name"] as? String, !name.isEmpty, !titles.contains(name) { titles.append(name) }
        }
        return titles
    }
}
