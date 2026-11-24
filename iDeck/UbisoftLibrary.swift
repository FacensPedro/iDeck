import Foundation

/// A Ubisoft game: one Ubisoft Connect installed into the prefix, or one the iDeck
/// account owns (from Ubisoft's account service) that is not installed yet.
struct UbisoftGame: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The game's main program, when installed.
    let executable: URL?
    /// The game's portrait cover (Steam's library art for the same title), once found:
    /// the addresses to try in order (UbisoftCovers.urls).
    var coverURLs: [URL] = []
}

/// Covers for Ubisoft games. Ubisoft's account service gives only names, so the cover
/// is Steam's 600x900 library art of the game with the same title (most Ubisoft games
/// are also sold on Steam). Answers, including "none", are kept so the search runs once.
enum UbisoftCovers {
    /// v2 (2.13.2): searched without ®/™, which made Steam answer "none" for titles such
    /// as "Assassin's Creed® Chronicles: China"; v1 kept those answers for good.
    private static let storeKey = "ubisoft.coverAppIDs.v2"

    static func key(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// The cover addresses of a Steam app, in order. Steam moved the art of many games
    /// to store_item_assets (the old path answers 404 for them), and a few games have
    /// no portrait art at all: their header picture is the last choice.
    static func urls(appID: Int) -> [URL] {
        guard appID > 0 else { return [] }
        return ["https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900.jpg",
                "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg",
                "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900_2x.jpg",
                "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg"].compactMap(URL.init(string:))
    }

    /// The cached Steam app id for a title: nil when never searched, 0 when none was found.
    static func cached(_ title: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int])?[key(title)]
    }

    static func cachedURLs(_ title: String) -> [URL] { cached(title).map(urls(appID:)) ?? [] }

    /// The cover addresses for a title, searching Steam once; nil when Steam did not answer.
    static func coverURLs(for title: String) async -> [URL]? {
        if let known = cached(title) { return urls(appID: known) }
        guard let appID = await steamAppID(for: title) else { return nil }
        var store = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int]) ?? [:]
        store[key(title)] = appID
        UserDefaults.standard.set(store, forKey: storeKey)
        return urls(appID: appID)
    }

    /// Steam's store search: an exact title match first, then a title that starts with
    /// the Ubisoft name. 0 means Steam answered without a match; nil means no answer.
    private static func steamAppID(for title: String) async -> Int? {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        let term = title.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
        components.queryItems = [URLQueryItem(name: "term", value: term),
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
    /// Owned products by title key, from Ubisoft's ownership service (product id and manifest).
    private var products: [String: UbisoftOwnedProduct] = [:]
    private var downloadTask: (id: String, task: Task<Void, Never>)?

    private var task: Task<Void, Never>?
    /// A refresh asked for while one runs (a sign-in during the first load): run once more after it.
    private var refreshAgain = false

    /// An iDeck Ubisoft session is saved. Published so the store page follows a sign-in
    /// or sign-out made in Settings without waiting for Windows to change state.
    @Published private(set) var signedIn = UbisoftSavedSession.load() != nil

    /// Installed games and the account's titles (Ubisoft's GraphQL service) are shown as
    /// soon as they are known. The ownership service (the demux), which only adds each
    /// game's product id and manifest for installing, is asked afterwards: 2.13.0 waited
    /// for it before showing anything, and the library stayed on "loading" while it did.
    func refresh() {
        signedIn = UbisoftSavedSession.load() != nil
        guard task == nil else { refreshAgain = true; return }
        refreshing = true
        task = Task { [weak self] in
            let drive = MadeiraDock.drive
            let installed = await Task.detached(priority: .utility) { Self.installedGames(drive: drive) }.value
            var owned: [String] = []
            var failure: String?
            // current() renews an expired session with its remember-me ticket.
            let session = await UbisoftSavedSession.current()
            if let session {
                do { owned = try await Self.ownedTitles(session: session) }
                catch {
                    failure = "Ubisoft: " + tr("Could not load the owned games.")
                    AppLog.record("[ubisoft-library] owned games: \(error.localizedDescription)")
                }
            } else if UbisoftSavedSession.load() != nil {
                failure = "Ubisoft: " + tr("The Ubisoft session expired. Sign in again in Settings.")
            }
            guard let self else { return }
            if session == nil { self.products = [:] }
            self.publish(installed: installed, owned: owned)
            self.error = failure
            self.refreshing = false
            Task { await self.findCovers() }
            AppLog.record("[ubisoft-library] installed=\(installed.count) owned=\(owned.count) signed-in=\(session != nil)")

            if session != nil {
                var products: [UbisoftOwnedProduct] = []
                do {
                    let client = try await UbisoftContentClient.signedIn()
                    defer { client.close() }
                    products = try await client.ownedGames()
                } catch {
                    AppLog.record("[ubisoft-library] ownership service: \(error.localizedDescription)")
                }
                for product in products where product.productType == 0 && !product.manifest.isEmpty && !product.name.isEmpty {
                    self.products[Self.key(product.name)] = product
                    if !owned.contains(where: { Self.key($0) == Self.key(product.name) }) { owned.append(product.name) }
                }
                if !products.isEmpty {
                    self.publish(installed: installed, owned: owned)
                    self.error = nil
                    Task { await self.findCovers() }   // titles only the ownership service named
                }
            }
            self.task = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
                return
            }
        }
    }

    private func publish(installed: [UbisoftGame], owned: [String]) {
        let names = Set(installed.map { Self.key($0.title) })
        let missing = owned.filter { !names.contains(Self.key($0)) }
            .map { UbisoftGame(id: "owned:" + Self.key($0), title: $0, executable: nil) }
        games = (installed + missing).map { game in
            var game = game
            let known = games.first(where: { $0.id == game.id })?.coverURLs ?? []
            game.coverURLs = known.isEmpty ? UbisoftCovers.cachedURLs(game.title) : known
            return game
        }
    }

    /// Titles whose cover is being looked up.
    private var coverLookups = Set<String>()

    /// Looks up the covers not cached yet, six titles at a time, and shows each as it
    /// arrives. Started as soon as the list is shown (2.13.1 waited for the ownership
    /// service first, so the cards stayed black for up to a minute).
    private func findCovers() async {
        var missing = games.filter { $0.coverURLs.isEmpty && UbisoftCovers.cached($0.title) == nil }
            .map(\.title).filter { coverLookups.insert($0).inserted }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: (String, [URL]?).self) { group in
            for _ in 0..<6 where !missing.isEmpty {
                let title = missing.removeFirst()
                group.addTask { (title, await UbisoftCovers.coverURLs(for: title)) }
            }
            while let (title, urls) = await group.next() {
                coverLookups.remove(title)
                if let urls {
                    for index in games.indices where games[index].title == title { games[index].coverURLs = urls }
                }
                if !missing.isEmpty {
                    let next = missing.removeFirst()
                    group.addTask { (next, await UbisoftCovers.coverURLs(for: next)) }
                }
            }
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

    func game(_ id: String) -> UbisoftGame? { games.first { $0.id == id } }

    func install(_ game: UbisoftGame) {
        guard game.executable == nil else { return }
        // Errors stay with the game (its page and card), as for the other stores.
        if AntiCheatPolicy.isBlocked(title: game.title) {
            downloads[game.id] = Download(state: .failed(AntiCheatPolicy.message), step: "")
            return
        }
        guard UbisoftSavedSession.load() != nil else {
            downloads[game.id] = Download(state: .failed(tr("Sign in to Ubisoft in Settings › Stores & launchers › Ubisoft Connect.")), step: "")
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
            GameLanguage.rememberKnown("ubisoft:\(game.id)", manifest.languages.sorted())
            let wanted = GameLanguage.choice("ubisoft:\(game.id)").flatMap { tag in
                manifest.languages.first { $0.lowercased() == tag.lowercased() }
            } ?? Self.preferredLanguage(available: manifest.languages)
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
                // A failed install is removed, as Stop does: no half game is left.
                let name = EALibrary.safeName(game.title)
                try? FileManager.default.removeItem(at: MadeiraDock.drive.appendingPathComponent(Self.installRoot, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true))
                try? FileManager.default.removeItem(at: Self.support.appendingPathComponent(name + ".journal"))
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
