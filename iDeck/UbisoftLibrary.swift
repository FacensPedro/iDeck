import Foundation

/// A Ubisoft game: one Ubisoft Connect installed into the prefix, or one the iDeck
/// account owns (from Ubisoft's account service) that is not installed yet.
struct UbisoftGame: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The game's main program, when installed.
    let executable: URL?
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
            self.games = installed + missing
            self.error = failure
            self.refreshing = false
            self.task = nil
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
