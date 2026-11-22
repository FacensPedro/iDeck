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

    /// A game being installed by iDeck (keyed by the game's id in `games`).
    struct Download: Equatable {
        enum State: Equatable { case queued, active, paused, failed(String) }
        var state: State
        var step: String
        var done: UInt64 = 0
        var total: UInt64 = 0
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }
    @Published private(set) var downloads: [String: Download] = [:]
    @Published var downloadError: String?
    /// Owned products by title key, from Ubisoft's ownership service (product id and manifest).
    private var products: [String: UbisoftOwnedProduct] = [:]
    private var downloadTask: (id: String, task: Task<Void, Never>)?

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
            // The ownership service also names each game's product id and newest
            // manifest, which installing needs; its list replaces the account's when it answers.
            var products: [UbisoftOwnedProduct] = []
            if UbisoftSavedSession.load() != nil, let client = try? await UbisoftContentClient.signedIn() {
                products = (try? await client.ownedGames()) ?? []
                client.close()
            }
            guard let self else { return }
            for product in products where product.productType == 0 && !product.manifest.isEmpty && !product.name.isEmpty {
                self.products[Self.key(product.name)] = product
                if !owned.contains(where: { Self.key($0) == Self.key(product.name) }) { owned.append(product.name) }
            }
            if !products.isEmpty { failure = nil }
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

    // MARK: Installing (iDeck's own download, as for the other stores)

    static let installRoot = "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games"
    nonisolated private static let installedKey = "ubisoft.installedByIDeck"
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira/ubisoft-downloads", isDirectory: true)
    }

    /// Games iDeck installed: product id -> folder under drive_c.
    nonisolated static var installedByIDeck: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: installedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: installedKey) }
    }

    func canInstall(_ game: UbisoftGame) -> Bool { game.executable == nil }

    func install(_ game: UbisoftGame) {
        guard game.executable == nil else { return }
        if AntiCheatPolicy.isBlocked(title: game.title) { downloadError = AntiCheatPolicy.message; return }
        guard UbisoftSavedSession.load() != nil else {
            downloadError = tr("Sign in to Ubisoft in Settings › Stores & launchers › Ubisoft Connect.")
            return
        }
        if let current = downloads[game.id], current.state == .active || current.state == .queued { return }
        let previous = downloads[game.id]
        downloads[game.id] = Download(state: .queued, step: tr("Waiting…"), done: previous?.done ?? 0, total: previous?.total ?? 0)
        pumpDownloads()
    }

    func pause(_ game: UbisoftGame) {
        if downloadTask?.id == game.id { downloadTask?.task.cancel() }
        if downloads[game.id] != nil { downloads[game.id]?.state = .paused }
    }

    /// Stops the download and removes what it wrote.
    func cancel(_ game: UbisoftGame) {
        pause(game)
        downloads[game.id] = nil
        let folder = MadeiraDock.drive.appendingPathComponent(Self.installRoot, isDirectory: true)
            .appendingPathComponent(EALibrary.safeName(game.title), isDirectory: true)
        let journal = Self.support.appendingPathComponent(EALibrary.safeName(game.title) + ".journal")
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: journal)
        }
        AppLog.record("[ubisoft-download] stopped \(game.title)")
    }

    private func pumpDownloads() {
        guard downloadTask == nil,
              let next = downloads.first(where: { $0.value.state == .queued }),
              let game = games.first(where: { $0.id == next.key }) else { return }
        downloads[game.id]?.state = .active
        let task = Task { @MainActor [weak self] in
            await self?.runDownload(game)
            self?.downloadTask = nil
            self?.pumpDownloads()
        }
        downloadTask = (game.id, task)
    }

    private func runDownload(_ game: UbisoftGame) async {
        let id = game.id
        func step(_ text: String) {
            downloads[id]?.step = text
            AppLog.record("[ubisoft-download] \(game.title): \(text)")
        }
        var client: UbisoftContentClient?
        defer { client?.close() }
        do {
            // Ubisoft's games start the launcher's service: it is installed first, as in Settings.
            if SystemCoordinator.StoreClient.ubisoft.installedURL == nil {
                step(tr("Installing Ubisoft Connect…"))
                try await SystemCoordinator.StoreClient.installWithoutWine(.ubisoft) { _ in }
                SystemCoordinator.StoreClient.prepareInstallEnvironment()
            }
            step(tr("Signing in to Ubisoft…"))
            let signedIn = try await UbisoftContentClient.signedIn()
            client = signedIn
            var product = products[Self.key(game.title)]
            if product == nil {
                for owned in try await signedIn.ownedGames() where owned.productType == 0 && !owned.manifest.isEmpty {
                    products[Self.key(owned.name)] = owned
                }
                product = products[Self.key(game.title)]
            }
            guard let product else { throw UbisoftDemuxError.refused(tr("Ubisoft does not offer a download of this game for this account")) }
            step(tr("Reading the game's file list…"))
            let manifestURL = try await signedIn.signedURLs(product: product.productID, paths: ["manifests/\(product.manifest).manifest"])
            let (manifestData, manifestResponse) = try await URLSession.shared.data(from: manifestURL[0])
            guard (manifestResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                throw UbisoftDemuxError.refused("manifest HTTP \((manifestResponse as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            var manifest = try UbisoftManifest.parse(manifestData, language: "en-US")
            let wanted = Self.preferredLanguage(available: manifest.languages)
            if wanted.lowercased() != "en-us" { manifest = try UbisoftManifest.parse(manifestData, language: wanted) }
            let name = EALibrary.safeName(game.title)
            let relative = Self.installRoot + "/" + name
            let folder = MadeiraDock.drive.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            let journal = Self.support.appendingPathComponent(name + ".journal")
            downloads[id]?.total = manifest.totalBytes
            AppLog.record("[ubisoft-download] start \(game.title) product=\(product.productID) files=\(manifest.files.count) bytes=\(manifest.totalBytes) language=\(wanted) compression=\(manifest.compression)")
            step(tr("Downloading…"))
            let title = game.title
            try await UbisoftInstaller(client: signedIn, product: product.productID, manifest: manifest, folder: folder, journal: journal)
                .run { progress in
                    guard ProgressThrottle.allow("ubisoft:" + id, state: "dl", done: progress.done, total: progress.total) else { return }
                    DownloadLog.progress(store: "Ubisoft Connect", name: title, done: progress.done, total: progress.total)
                    Task { @MainActor in
                        UbisoftLibrary.shared.downloads[id]?.done = progress.done
                        UbisoftLibrary.shared.downloads[id]?.total = progress.total
                    }
                }
            try? FileManager.default.removeItem(at: journal)
            var record = Self.installedByIDeck
            record[String(product.productID)] = relative
            Self.installedByIDeck = record
            Self.writeRegistry(productID: product.productID, relative: relative)
            downloads[id] = nil
            DownloadLog.ended(store: "Ubisoft Connect", name: game.title, outcome: "finished")
            AppLog.record("[ubisoft-download] done \(game.title)")
            refresh()
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[id] != nil { downloads[id]?.state = .paused }
                DownloadLog.ended(store: "Ubisoft Connect", name: game.title, outcome: "paused")
            } else {
                downloads[id]?.state = .failed(error.localizedDescription)
                downloadError = error.localizedDescription
                DownloadLog.ended(store: "Ubisoft Connect", name: game.title, outcome: "failed: " + error.localizedDescription)
                AppLog.record("[ubisoft-download] failed \(game.title): \(error.localizedDescription)")
            }
        }
        if !downloads.values.contains(where: { $0.state == .active || $0.state == .queued }) {
            ResourceGovernor.shared.releaseAfterDownload()
        }
    }

    /// The device's language when the game has it (pt-BR, es-ES, ...), otherwise English.
    nonisolated static func preferredLanguage(available: Set<String>) -> String {
        let device = (Locale.preferredLanguages.first ?? "en-US").lowercased()
        let lookup = Dictionary(available.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        if let exact = lookup[device] { return exact }
        let base = String(device.prefix(2))
        if let same = available.first(where: { $0.lowercased().hasPrefix(base + "-") }) { return same }
        return lookup["en-us"] ?? "en-US"
    }

    /// HKLM\Software\[Wow6432Node\]Ubisoft\Launcher\Installs\<id>\InstallDir, as Ubisoft
    /// Connect writes it; only while no Windows program runs (the .reg files are Wine's then).
    nonisolated static func writeRegistry(productID: UInt32, relative: String) {
        guard !ideck_wineprocess_running() else { return }
        let path = "C:\\" + relative.replacingOccurrences(of: "/", with: "\\") + "\\"
        let value = SteamInstallValue(hive: .machine, key: "Software\\Ubisoft\\Launcher\\Installs\\\(productID)",
                                      name: "InstallDir", data: .string(path), followsInstall: true)
        _ = try? EARegistry.write([value], prefix: MadeiraDock.prefix)
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
        // Games iDeck installed whose registry value is not written yet (a Windows
        // program was running when the download ended): written now when possible.
        for (id, relative) in installedByIDeck where folders[id] == nil {
            folders[id] = "c:/" + relative
            writeRegistry(productID: UInt32(id) ?? 0, relative: relative)
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
