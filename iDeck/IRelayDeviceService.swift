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
        EpicLibrary.installRoot + "/",
    ]

    private let queue = DispatchQueue(label: "ideck.irelay.service", qos: .userInitiated)
    private var listener: NWListener?

    static var drive: URL { EpicLibrary.drive }
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
            return .json(["name": name, "app": "iDeck", "version": version, "protocol": 2, "freeBytes": free])
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

    // MARK: Libraries

    @MainActor
    private static func library() async -> [String: Any] {
        let steam = SteamOwnedGamesModel.shared
        let prefix = Self.prefix
        if SteamSignIn.isSignedIn && steam.games.isEmpty { await steam.refresh() }
        steam.refreshInstalledApps(prefixPath: prefix)
        let steamGames: [[String: Any]] = steam.games.filter { $0.type == .game }.map { game in
            [
                "appId": game.appID, "name": game.name, "installDir": game.installDir,
                "installed": steam.installedApps.contains(game.appID),
                "dlc": (steam.availableDLC[game.appID] ?? []).map { id in
                    ["appId": id, "name": steam.dlcMetadata[id]?.name ?? "DLC \(id)",
                     "installed": steam.installedDLC[game.appID]?.contains(id) == true] as [String: Any]
                },
            ]
        }
        let gog = GOGLibraryModel.shared
        gog.refreshInstalled(prefixPath: prefix)
        let gogGames: [[String: Any]] = gog.games.filter(\.worksOnWindows).map { game in
            ["id": game.id, "title": game.title, "cover": game.artworkCandidates.first?.absoluteString ?? "",
             "installed": gog.installed[game.id] != nil]
        }
        let epic = EpicLibrary.shared
        let epicGames: [[String: Any]] = epic.owned.map { game in
            ["appName": game.appName, "title": game.title, "namespace": game.namespace,
             "catalogItemId": game.catalogItemID, "cover": game.cover?.absoluteString ?? "",
             "folderName": game.folderName, "installed": epic.installed[game.appName] != nil]
        }
        return [
            "steam": ["signedIn": SteamSignIn.isSignedIn, "account": SteamSignIn.accountName ?? "", "games": steamGames],
            "gog": ["signedIn": gog.isSignedIn, "games": gogGames],
            "epic": ["signedIn": epic.signedIn, "games": epicGames],
        ]
    }

    @MainActor
    private static func steamDLC(_ appID: UInt32) async -> [String: Any] {
        let steam = SteamOwnedGamesModel.shared
        await steam.loadDLC(appID: appID)
        steam.refreshInstalledDLC(appID: appID, prefixPath: prefix)
        return ["dlc": (steam.availableDLC[appID] ?? []).map { id in
            ["appId": id, "name": steam.dlcMetadata[id]?.name ?? "DLC \(id)",
             "installed": steam.installedDLC[appID]?.contains(id) == true] as [String: Any]
        }]
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { data, _, complete, error in
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
