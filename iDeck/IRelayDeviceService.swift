import CryptoKit
import Foundation
import Network
import UIKit

/// The service iRelay reaches over the USB cable (usbmux delivers the PC's
/// connections to this port on the loopback interface). Plain HTTP/1.1, JSON:
///
/// - `GET /info`: this device's name, iDeck's version and free space.
/// - `GET /library`: the Steam, GOG and Epic libraries iDeck is signed in to,
///   with what is installed (DLC included for Steam games).
/// - `POST /steam/dlc?app=<id>`: loads a Steam game's DLC list.
/// - `GET /files?root=<folder>`: files already in an install folder (path,
///   size, modification time), so iRelay sends only what differs.
/// - `PUT /file?root=<folder>&path=<file>&mtime=<seconds>`: one file's bytes.
/// - `DELETE /file?root=<folder>&path=<file>`: a file the PC no longer has.
/// - `POST /finish`: the install record (Steam's appmanifest, an Epic record,
///   DLC), written once every file is in place; iDeck then lists the game.
///
/// `root` is relative to drive_c and must be inside one of iDeck's game
/// folders (`IRelayDeviceService.roots`); no path may leave it.
final class IRelayDeviceService: @unchecked Sendable {
    static let shared = IRelayDeviceService()
    static let port: UInt16 = 27093
    static let installedNotification = Notification.Name("iDeckIRelayInstalled")

    /// Install folders iRelay may write to, relative to drive_c.
    static let roots = [
        SteamInstallPaths.libraryRelative + "/common/",
        "GOG Games/",
        "Program Files/Epic Games/",
    ]

    private let queue = DispatchQueue(label: "ideck.irelay.service", qos: .userInitiated)
    private var listener: NWListener?

    /// Documents/wine/drive_c (as EpicLibrary.drive, usable off the main actor).
    static var drive: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c", isDirectory: true)
    }
    static var prefix: URL { drive.deletingLastPathComponent() }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            guard let port = NWEndpoint.Port(rawValue: Self.port),
                  let listener = try? NWListener(using: parameters, on: port) else {
                AppLog.record("[irelay] could not listen on port \(Self.port)")
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                IRelayHTTPConnection(connection: connection, queue: self.queue, service: self).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    AppLog.record("[irelay] service failed: \(error)")
                    self?.queue.asyncAfter(deadline: .now() + 2) {
                        self?.listener?.cancel()
                        self?.listener = nil
                        self?.start()
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    // MARK: Paths

    /// A relative path made of plain names, or nil.
    static func clean(_ text: String) -> String? {
        let parts = text.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.count < 64 else { return nil }
        for part in parts where part == "." || part == ".." || part.contains("\0") || part.count > 255 { return nil }
        return parts.joined(separator: "/")
    }

    /// An install folder iRelay may use (one level below a root at least).
    static func folder(_ root: String) -> URL? {
        guard let relative = clean(root),
              roots.contains(where: { (relative + "/").hasPrefix($0) && relative.count > $0.count }) else { return nil }
        return drive.appendingPathComponent(relative, isDirectory: true)
    }

    static func file(root: String, path: String) -> URL? {
        guard let folder = folder(root), let relative = clean(path) else { return nil }
        let url = folder.appendingPathComponent(relative)
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    // MARK: Requests

    func handle(_ request: IRelayHTTPRequest) async -> IRelayHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/info"):
            let values = try? Self.prefix.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free: Int64 = values?.volumeAvailableCapacityForImportantUsage ?? 0
            let name = await MainActor.run { UIDevice.current.name }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return .json(["name": name, "app": "iDeck", "version": version, "protocol": 3, "freeBytes": free])
        case ("PUT", "/write"):
            return Self.write(request)
        case ("POST", "/install"):
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .status(400) }
            do {
                try await Self.install(json)
                return .json(["ok": true])
            } catch {
                return .error(422, error.localizedDescription)
            }
        case ("POST", "/uninstall"):
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .status(400) }
            do {
                try await MainActor.run { try Self.uninstall(json) }
                return .json(["ok": true])
            } catch {
                return .error(422, error.localizedDescription)
            }
        case ("GET", "/installs"):
            return .json(await Self.installs())
        case ("POST", "/downloads/control"):
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .status(400) }
            do {
                try await Self.downloadControl(json)
                return .json(["ok": true])
            } catch {
                return .error(422, error.localizedDescription)
            }
        case ("DELETE", "/logs"):
            // iRelay's "Clear" on iDeck bugs: the same as Bugs & logs › Clear logs.
            AppLog.clear()
            if let wine = await MainActor.run(body: { BugReportModel.wineLogURL }) { try? FileManager.default.removeItem(at: wine) }
            return .json(["ok": true])
        case ("GET", "/logs"):
            return .json(await Self.logs())
        case ("GET", "/library"):
            return .json(await Self.library())
        case ("POST", "/steam/dlc"):
            guard let app = request.query["app"].flatMap(UInt32.init) else { return .status(400) }
            return .json(await Self.steamDLC(app))
        case ("GET", "/files"):
            guard let folder = request.query["root"].flatMap(Self.folder) else { return .status(400) }
            return .json(["files": Self.listing(folder)])
        case ("DELETE", "/file"):
            guard let root = request.query["root"], let path = request.query["path"],
                  let url = Self.file(root: root, path: path) else { return .status(400) }
            try? FileManager.default.removeItem(at: url)
            return .json(["ok": true])
        case ("PUT", "/file"):
            // The body was written to the file as it arrived (IRelayHTTPConnection).
            if let failure = request.uploadError { return IRelayHTTPResponse.error(507, failure) }
            return .json(["ok": true])
        case ("POST", "/finish"):
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .status(400) }
            do {
                try await Self.finish(json)
                return .json(["ok": true])
            } catch {
                return .error(422, error.localizedDescription)
            }
        default:
            return .status(404)
        }
    }

    /// Where a PUT body goes: the file, its modification date.
    func uploadTarget(_ request: IRelayHTTPRequest) -> (URL, Date?)? {
        guard request.method == "PUT", request.path == "/file",
              let root = request.query["root"], let path = request.query["path"],
              let url = Self.file(root: root, path: path) else { return nil }
        return (url, request.query["mtime"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
    }

    private static func listing(_ folder: URL) -> [[String: Any]] {
        var files: [[String: Any]] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let base = folder.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base), !path.hasSuffix(".irelay-part") else { continue }
            files.append(["p": String(path.dropFirst(base.count)), "s": values.fileSize ?? 0,
                          "m": Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)])
        }
        return files
    }

    // MARK: Downloads iRelay starts

    /// One chunk iRelay downloaded and decoded: written at its offset in a
    /// file of a game being installed, after checking its SHA-1.
    private static func write(_ request: IRelayHTTPRequest) -> IRelayHTTPResponse {
        guard let root = request.query["root"], let path = request.query["path"],
              let url = file(root: root, path: path),
              let offset = request.query["offset"].flatMap(UInt64.init),
              let sha = request.query["sha"]?.lowercased(), sha.count == 40,
              let body = request.body else { return .status(400) }
        let digest = Insecure.SHA1.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard digest == sha else { return .error(409, "SHA-1 mismatch") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            if let size = request.query["size"].flatMap(Int64.init) {
                var info = stat()
                if fstat(fd, &info) == 0, info.st_size < size { _ = ftruncate(fd, off_t(size)) }
            }
            let written = body.withUnsafeBytes { pwrite(fd, $0.baseAddress, body.count, off_t(offset)) }
            guard written == body.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return .json(["ok": true])
        } catch {
            return .error(507, error.localizedDescription)
        }
    }

    /// Starts iDeck's own install of a game (or a Steam DLC) from iRelay. Steam
    /// installs then hand their chunks to iRelay (DepotDownloader.processOnPC).
    @MainActor
    private static func install(_ json: [String: Any]) async throws {
        let prefix = Self.prefix
        switch json["store"] as? String {
        case "steam":
            guard let appID = (json["appId"] as? NSNumber)?.uint32Value else { throw FinishError(errorDescription: "Missing app.") }
            let steam = SteamOwnedGamesModel.shared
            if let dlc = (json["dlcId"] as? NSNumber)?.uint32Value {
                steam.startDLCInstall(appID: appID, dlcAppID: dlc, prefixPath: prefix)
            } else {
                steam.startInstall(appID: appID, prefixPath: prefix)
            }
        case "gog":
            guard let id = (json["id"] as? NSNumber)?.intValue,
                  let game = GOGLibraryModel.shared.games.first(where: { $0.id == id }) else {
                throw FinishError(errorDescription: "GOG game not found in iDeck's library.")
            }
            GOGLibraryModel.shared.install(game, prefixPath: prefix) { _ in
                NotificationCenter.default.post(name: installedNotification, object: nil)
            }
        case "epic":
            guard let app = json["appName"] as? String, EpicLibrary.shared.game(app) != nil else {
                throw FinishError(errorDescription: "Epic game not found in iDeck's library.")
            }
            EpicLibrary.shared.install(app)
        default:
            throw FinishError(errorDescription: "Unknown store.")
        }
    }

    /// Transfer controls are executed by the owning store on iDeck, not by
    /// killing the PC-side worker. This also stops iDeck's own HTTP downloads.
    @MainActor
    private static func downloadControl(_ json: [String: Any]) async throws {
        guard let store = json["store"] as? String,
              let action = json["action"] as? String,
              ["pause", "resume", "stop"].contains(action) else {
            throw FinishError(errorDescription: "Invalid download control.")
        }
        switch store {
        case "steam":
            guard let id = (json["id"] as? NSNumber)?.uint32Value else {
                throw FinishError(errorDescription: "Invalid Steam app ID.")
            }
            let steam = SteamOwnedGamesModel.shared
            switch action {
            case "pause": steam.pauseInstall(appID: id)
            case "resume": steam.resumeInstall(appID: id)
            default: await steam.cancelInstallAndWait(appID: id)
            }
        case "gog":
            guard let id = (json["id"] as? NSNumber)?.intValue,
                  let game = GOGLibraryModel.shared.games.first(where: { $0.id == id }) else {
                throw FinishError(errorDescription: "GOG game not found.")
            }
            let gog = GOGLibraryModel.shared
            switch action {
            case "pause": gog.pauseDownload(game)
            case "resume": gog.resumeDownload(game)
            default: await gog.cancelDownloadAndWait(game)
            }
        case "epic":
            guard let app = json["id"] as? String, EpicLibrary.shared.game(app) != nil else {
                throw FinishError(errorDescription: "Epic game not found.")
            }
            switch action {
            case "pause": EpicLibrary.shared.pause(app)
            case "resume": EpicLibrary.shared.install(app)
            default: await EpicLibrary.shared.cancelAndWait(app)
            }
        default:
            throw FinishError(errorDescription: "Unknown game store.")
        }
    }

    /// iDeck's own downloads, for iRelay's Transfers.
    @MainActor
    private static func installs() -> [String: Any] {
        var list: [[String: Any]] = []
        let steam = SteamOwnedGamesModel.shared
        // A finished install keeps its last progress in the model: only running ones count.
        for (id, progress) in steam.downloadProgress where steam.installingApps.contains(id) || steam.installingDLC[id] != nil || steam.pausedInstalls.contains(id) {
            let name = steam.games.first { $0.appID == id }?.name ?? "App \(id)"
            list.append(["store": "steam", "id": id, "title": name,
                         "phase": steam.pausedInstalls.contains(id) ? "paused" : progress.phase.rawValue,
                         "done": progress.doneBytes, "total": progress.totalBytes,
                         "error": steam.downloadErrors[id] ?? ""])
        }
        for id in steam.pausedInstalls where steam.downloadProgress[id] == nil {
            let name = steam.games.first { $0.appID == id }?.name ?? "App \(id)"
            list.append(["store": "steam", "id": id, "title": name, "phase": "paused",
                         "done": 0, "total": 0, "error": ""])
        }
        for (id, error) in steam.downloadErrors where steam.downloadProgress[id] == nil {
            let name = steam.games.first { $0.appID == id }?.name ?? "App \(id)"
            list.append(["store": "steam", "id": id, "title": name, "phase": "failed", "done": 0, "total": 0, "error": error])
        }
        let gog = GOGLibraryModel.shared
        for (id, fraction) in gog.downloadProgress {
            list.append(["store": "gog", "id": id, "title": gog.games.first { $0.id == id }?.title ?? "GOG \(id)",
                         "phase": gog.pausedDownloads.contains(id) ? "paused" : "downloading",
                         "done": Int(fraction * 1000), "total": 1000,
                         "error": gog.downloadErrors[id] ?? ""])
        }
        for id in gog.pausedDownloads where gog.downloadProgress[id] == nil {
            list.append(["store": "gog", "id": id,
                         "title": gog.games.first { $0.id == id }?.title ?? "GOG \(id)",
                         "phase": "paused", "done": 0, "total": 0, "error": ""])
        }
        let epic = EpicLibrary.shared
        for (app, download) in epic.downloads {
            var error = ""
            if case .failed(let reason) = download.state { error = reason }
            list.append(["store": "epic", "id": app, "title": epic.game(app)?.title ?? app, "phase": download.state == .paused ? "paused" : "\(download.state)",
                         "done": download.progress.fraction * 1000, "total": 1000, "error": error])
        }
        return ["installs": list]
    }

    // MARK: Logs

    /// iDeck's problems for iRelay's "iDeck bugs" view: the same scan as the
    /// bug report, over iDeck's log and the last Wine log, plus the log's tail.
    private static func logs() async -> [String: Any] {
        let wineURL = await MainActor.run { BugReportModel.wineLogURL }
        func tail(_ url: URL?, _ bytes: Int) -> String {
            guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
            return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }
        let app = tail(AppLog.fileURL, 512 << 10)
        let wine = tail(wineURL, 2 << 20)
        let issues = LogIssueScanner.scan(app, source: .app, limit: 5000) + LogIssueScanner.scan(wine, source: .wine, limit: 5000)
        let recent = app.split(whereSeparator: \.isNewline).suffix(300).joined(separator: "\n")
        return ["issues": issues.map(\.copyText), "log": recent]
    }

    // MARK: Libraries

    @MainActor
    private static func library() async -> [String: Any] {
        let steam = SteamOwnedGamesModel.shared
        let prefix = Self.prefix
        let drive = Self.drive
        if SteamSignIn.isSignedIn && steam.games.isEmpty { await steam.refresh() }
        steam.refreshInstalledApps(prefixPath: prefix)
        // What is installed is read from the device's own folders every time
        // (not from the views' state), so games copied earlier, by any version
        // of iRelay, are always found.
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        let records = Set(((try? FileManager.default.contentsOfDirectory(atPath: steamApps.path)) ?? []).compactMap { name -> UInt32? in
            guard name.hasPrefix("appmanifest_"), name.hasSuffix(".acf") else { return nil }
            return UInt32(name.dropFirst("appmanifest_".count).dropLast(4))
        })
        func dlc(_ appID: UInt32) -> [[String: Any]] { dlcEntries(appID, steamApps: steamApps) }
        var steamGames: [[String: Any]] = steam.games.filter { $0.type == .game }.map { game in
            let installed = records.contains(game.appID)
            let build = installed ? SteamInstallFiles.buildID(appID: Int(game.appID), steamApps: steamApps) : nil
            // An update only when Steam's current build differs from the installed record's.
            let update = installed && game.buildID != 0 && build != nil && build != Int(game.buildID)
            let size = game.displaySizeForWindows(installedBytes: installed ? (steam.installedSizes[game.appID] ?? 0) : 0)
            return ["appId": game.appID, "name": game.name, "installDir": game.installDir,
                    "installed": installed, "update": update, "size": size.bytes,
                    "sizeSource": size.isRequirement ? "requirements" : "metadata",
                    "requiredSpaceGB": size.isRequirement ? (SteamAppInfo.publishedRequiredSpaceGB(for: game.appID) ?? 0) : 0,
                    "dlc": dlc(game.appID)]
        }
        // Installed games the owned list does not have (not loaded yet, or another account's).
        let listed = Set(steam.games.map(\.appID))
        // Only games Madeira Dock can start: not Steamworks redistributables
        // (228980) or other records that only lend depots.
        for game in MadeiraDock.games(drive: drive) where !listed.contains(UInt32(game.id)) {
            let id = UInt32(game.id)
            let size = SteamAppInfo(appID: id).displaySizeForWindows(installedBytes: steam.installedSizes[id] ?? 0)
            steamGames.append(["appId": id, "name": game.name, "installDir": game.installDir,
                               "installed": true, "size": size.bytes,
                               "sizeSource": size.isRequirement ? "requirements" : "metadata",
                               "requiredSpaceGB": size.isRequirement ? (SteamAppInfo.publishedRequiredSpaceGB(for: id) ?? 0) : 0,
                               "dlc": dlc(id)])
        }
        let gog = GOGLibraryModel.shared
        gog.refreshInstalled(prefixPath: prefix)
        let gogInstalled = await Task.detached(priority: .userInitiated) { GOGInstallScanner.installed(in: drive) }.value
        // GOG editions do not always publish a size in the initial owned
        // list. Ask GOG's content plan for the requested legacy title instead
        // of reporting a guessed fixed-size download.
        if gog.isSignedIn {
            for game in gog.games where game.worksOnWindows &&
                game.title.localizedCaseInsensitiveContains("Oblivion") &&
                gog.downloadSizes[game.id] == nil {
                await gog.loadSize(for: game)
            }
        }
        var gogGames: [[String: Any]] = gog.games.filter(\.worksOnWindows).map { game in
            ["id": game.id, "title": game.title, "cover": game.artworkCandidates.first?.absoluteString ?? "",
             "installed": gogInstalled[game.id] != nil,
             "size": gog.installedSizes[game.id].flatMap { $0 > 0 ? $0 : nil } ?? (gog.downloadSizes[game.id] ?? 0)]
        }
        let gogListed = Set(gog.games.map(\.id))
        for (id, game) in gogInstalled where !gogListed.contains(id) {
            gogGames.append(["id": id, "title": game.name, "cover": "", "installed": true,
                             "size": gog.installedSizes[id] ?? 0])
        }
        let epic = EpicLibrary.shared
        epic.reloadInstalled()
        var epicGames: [[String: Any]] = epic.owned.map { game in
            ["appName": game.appName, "title": game.title, "namespace": game.namespace,
             "catalogItemId": game.catalogItemID, "cover": game.cover?.absoluteString ?? "",
             "folderName": game.folderName, "installed": epic.installed[game.appName] != nil,
             "size": (epic.installed[game.appName]?.installBytes ?? 0) > 0 ? (epic.installed[game.appName]?.installBytes ?? 0) : (epic.manifestSizes[game.appName] ?? 0)]
        }
        let epicListed = Set(epic.owned.map(\.appName))
        for (app, game) in epic.installed where !epicListed.contains(app) {
            epicGames.append(["appName": app, "title": game.title, "namespace": game.namespace,
                              "catalogItemId": game.catalogItemID, "cover": "", "folderName": "", "installed": true,
                              "size": game.installBytes])
        }
        return [
            "steam": ["signedIn": SteamSignIn.isSignedIn || !records.isEmpty, "account": SteamSignIn.accountName ?? "", "games": steamGames],
            "gog": ["signedIn": gog.isSignedIn || !gogInstalled.isEmpty, "games": gogGames],
            "epic": ["signedIn": epic.signedIn || !epic.installed.isEmpty, "games": epicGames],
        ]
    }

    @MainActor
    private static func steamDLC(_ appID: UInt32) async -> [String: Any] {
        let steam = SteamOwnedGamesModel.shared
        await steam.loadDLC(appID: appID)
        steam.refreshInstalledDLC(appID: appID, prefixPath: prefix)
        return ["dlc": dlcEntries(appID, steamApps: SteamInstallPaths.steamApps(drive: drive))]
    }

    /// A game's DLC with their installed state and size (bytes, 0 = unknown).
    @MainActor
    private static func dlcEntries(_ appID: UInt32, steamApps: URL) -> [[String: Any]] {
        let steam = SteamOwnedGamesModel.shared
        let parent = steam.games.first { $0.appID == appID }
        return (steam.availableDLC[appID] ?? []).map { id in
            var bytes = parent?.depots.filter { $0.dlcAppID == id }.reduce(UInt64(0)) { $0 + max($1.maxSize, $1.publicSizeBytes) } ?? 0
            if bytes == 0 { bytes = steam.dlcMetadata[id]?.downloadSize(for: "windows") ?? 0 }
            return ["appId": id, "name": steam.dlcMetadata[id]?.name ?? "DLC \(id)", "size": bytes,
                    "installed": SteamDLCRecords.isInstalled(parentID: appID, dlcID: id, steamApps: steamApps)] as [String: Any]
        }
    }

    /// Uninstalls a game (or a Steam DLC) iRelay names.
    @MainActor
    private static func uninstall(_ json: [String: Any]) throws {
        let prefix = Self.prefix
        var removed = false
        switch json["store"] as? String {
        case "steam":
            guard let appID = (json["appId"] as? NSNumber)?.uint32Value else { break }
            let steam = SteamOwnedGamesModel.shared
            if let dlc = (json["dlcId"] as? NSNumber)?.uint32Value {
                removed = steam.uninstallDLC(appID: appID, dlcAppID: dlc, prefixPath: prefix)
            } else {
                removed = steam.uninstall(appID: appID, prefixPath: prefix)
            }
            steam.refreshInstalledApps(prefixPath: prefix)
        case "gog":
            if let id = (json["id"] as? NSNumber)?.intValue {
                removed = GOGLibraryModel.shared.uninstall(id, prefixPath: prefix)
            }
        case "epic":
            if let app = json["appName"] as? String, EpicLibrary.shared.installed[app] != nil {
                EpicLibrary.shared.uninstall(app)
                removed = true
            }
        default: break
        }
        guard removed else { throw FinishError(errorDescription: "Nothing to uninstall.") }
        NotificationCenter.default.post(name: installedNotification, object: nil)
    }

    struct FinishError: LocalizedError {
        let errorDescription: String?
    }

    /// The install record once every file is in place.
    @MainActor
    private static func finish(_ json: [String: Any]) async throws {
        let store = json["store"] as? String ?? ""
        let prefix = Self.prefix
        switch store {
        case "steam":
            guard let appID = (json["appId"] as? NSNumber)?.uint32Value,
                  let acf = json["acf"] as? String, acf.utf8.count < 4 << 20 else {
                throw FinishError(errorDescription: "Missing Steam install record.")
            }
            let steamApps = SteamInstallPaths.steamApps(drive: drive)
            try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
            try Data(acf.utf8).write(to: steamApps.appendingPathComponent("appmanifest_\(appID).acf"), options: .atomic)
            let files = (json["files"] as? [String] ?? []).compactMap(clean)
            for dlc in json["dlc"] as? [NSNumber] ?? [] {
                try SteamDLCRecords.markInstalled(parentID: appID, dlcID: dlc.uint32Value, files: files, steamApps: steamApps)
            }
            let steam = SteamOwnedGamesModel.shared
            steam.refreshInstalledApps(prefixPath: prefix)
            steam.refreshInstalledDLC(appID: appID, prefixPath: prefix)
        case "gog":
            GOGLibraryModel.shared.refreshInstalled(prefixPath: prefix)
        case "epic":
            guard let record = json["record"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: record),
                  let game = try? JSONDecoder().decode(EpicInstalledGame.self, from: data),
                  folder(game.folder) != nil else {
                throw FinishError(errorDescription: "Invalid Epic install record.")
            }
            EpicLibrary.shared.registerTransferred(game)
        default:
            throw FinishError(errorDescription: "Unknown store.")
        }
        AppLog.record("[irelay] installed from the PC: \(store) \(json["title"] as? String ?? "")")
        NotificationCenter.default.post(name: installedNotification, object: nil)
    }
}

// MARK: - HTTP

struct IRelayHTTPRequest {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Data?
    var uploadError: String?
}

struct IRelayHTTPResponse {
    var status: Int
    var body: Data

    static func json(_ value: Any) -> IRelayHTTPResponse {
        IRelayHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8))
    }

    static func status(_ code: Int) -> IRelayHTTPResponse { error(code, "HTTP \(code)") }

    static func error(_ code: Int, _ message: String) -> IRelayHTTPResponse {
        IRelayHTTPResponse(status: code, body: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data())
    }
}

/// One keep-alive HTTP/1.1 connection from iRelay. Bodies of uploads are
/// written to their file as they arrive; others (at most 16 MB) are kept.
final class IRelayHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let service: IRelayDeviceService
    private var buffer = Data()
    private var keep: IRelayHTTPConnection?

    init(connection: NWConnection, queue: DispatchQueue, service: IRelayDeviceService) {
        self.connection = connection
        self.queue = queue
        self.service = service
    }

    func start() {
        keep = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.keep = nil
            default: break
            }
        }
        connection.start(queue: queue)
        readHeader()
    }

    private func close() {
        connection.cancel()
        keep = nil
    }

    private func receive(_ then: @escaping (Data?) -> Void) {
        // Smaller receive slabs reduce peak Data allocation under memory pressure.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { data, _, complete, error in
            if let data, !data.isEmpty { then(data) } else if complete || error != nil { then(nil) } else { then(Data()) }
        }
    }

    private func readHeader() {
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            guard let request = parse(head) else { return close() }
            let length = Int(request.headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return close() }
            if let (url, mtime) = service.uploadTarget(request) {
                upload(request, to: url, mtime: mtime, length: length)
            } else {
                guard length <= 16 << 20 else { return close() }
                readBody(length) { [weak self] body in
                    var complete = request
                    complete.body = body
                    self?.respond(to: complete)
                }
            }
            return
        }
        guard buffer.count < 64 << 10 else { return close() }
        receive { [weak self] data in
            guard let self else { return }
            guard let data else { return self.close() }
            self.buffer.append(data)
            self.readHeader()
        }
    }

    private func parse(_ head: String) -> IRelayHTTPRequest? {
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2, let components = URLComponents(string: String(first[1])) else { return nil }
        var request = IRelayHTTPRequest()
        request.method = String(first[0])
        request.path = components.path
        for item in components.queryItems ?? [] { request.query[item.name] = item.value ?? "" }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            request.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return request
    }

    private func readBody(_ length: Int, then: @escaping (Data) -> Void) {
        if buffer.count >= length {
            let body = buffer.prefix(length)
            buffer.removeFirst(length)
            return then(Data(body))
        }
        receive { [weak self] data in
            guard let self else { return }
            guard let data else { return self.close() }
            self.buffer.append(data)
            self.readBody(length, then: then)
        }
    }

    private final class Upload {
        var request: IRelayHTTPRequest
        let url: URL, part: URL, mtime: Date?
        var handle: FileHandle?
        var remaining: Int
        init(request: IRelayHTTPRequest, url: URL, mtime: Date?, length: Int) {
            self.request = request; self.url = url; self.mtime = mtime; remaining = length
            part = url.appendingPathExtension("irelay-part")
        }
    }

    /// Streams the body into "<file>.irelay-part", then puts it in place.
    private func upload(_ request: IRelayHTTPRequest, to url: URL, mtime: Date?, length: Int) {
        let upload = Upload(request: request, url: url, mtime: mtime, length: length)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: upload.part.path, contents: nil)
            upload.handle = try FileHandle(forWritingTo: upload.part)
        } catch {
            upload.request.uploadError = error.localizedDescription
        }
        pump(upload)
    }

    private func pump(_ upload: Upload) {
        if !buffer.isEmpty && upload.remaining > 0 {
            let take = min(buffer.count, upload.remaining)
            if upload.request.uploadError == nil, let handle = upload.handle {
                do { try handle.write(contentsOf: buffer.prefix(take)) } catch { upload.request.uploadError = error.localizedDescription }
            }
            buffer.removeFirst(take)
            upload.remaining -= take
        }
        if upload.remaining == 0 { return finishUpload(upload) }
        receive { [weak self] data in
            guard let self else { return }
            guard let data else {
                try? upload.handle?.close()
                try? FileManager.default.removeItem(at: upload.part)
                return self.close()
            }
            self.buffer.append(data)
            self.pump(upload)
        }
    }

    private func finishUpload(_ upload: Upload) {
        try? upload.handle?.close()
        let manager = FileManager.default
        if upload.request.uploadError == nil {
            do {
                if manager.fileExists(atPath: upload.url.path) { try manager.removeItem(at: upload.url) }
                try manager.moveItem(at: upload.part, to: upload.url)
                if let mtime = upload.mtime { try? manager.setAttributes([.modificationDate: mtime], ofItemAtPath: upload.url.path) }
            } catch {
                upload.request.uploadError = error.localizedDescription
            }
        }
        if upload.request.uploadError != nil { try? manager.removeItem(at: upload.part) }
        respond(to: upload.request)
    }

    private func respond(to request: IRelayHTTPRequest) {
        Task {
            let response = await service.handle(request)
            let reason = response.status == 200 ? "OK" : "Error"
            var head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\n"
            head += "Content-Length: \(response.body.count)\r\nConnection: keep-alive\r\n\r\n"
            var out = Data(head.utf8)
            out.append(response.body)
            connection.send(content: out, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { return self.close() }
                self.queue.async { self.readHeader() }
            })
        }
    }
}
