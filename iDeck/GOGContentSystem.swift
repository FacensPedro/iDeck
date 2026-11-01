import CryptoKit
import Foundation

// GOG Galaxy's content system (generation 2), the way GOG Galaxy, gogdl and
// Heroic install games: the build's depots list every file of the game as
// zlib-compressed chunks, downloaded from GOG's CDN and assembled directly in
// the game folder. No offline installer is downloaded or run.
//
//   builds:   content-system.gog.com/products/<id>/os/windows/builds?generation=2
//   manifest: the build's link (zlib JSON): depots, installDirectory, offlineDepot
//   depot:    gog-cdn-fastly.gog.com/content-system/v2/meta/<aa>/<bb>/<hash>
//   chunks:   secure_link URL + /<aa>/<bb>/<compressedMd5>

enum GOGContentError: LocalizedError {
    case noBuild
    case invalidManifest
    case noDepots
    case checksum(String)

    var errorDescription: String? {
        switch self {
        case .noBuild: return "GOG has no Galaxy build of this game."
        case .invalidManifest: return "GOG returned an unreadable game manifest."
        case .noDepots: return "GOG lists no Windows files for this game in your language."
        case .checksum(let path): return "A downloaded part of \(path) is damaged."
        }
    }
}

struct GOGContentChunk {
    let md5: String
    let compressedMd5: String
    let size: Int64
    let compressedSize: Int64
}

struct GOGContentFile {
    let path: String          // relative, "/" separated
    let productID: String
    let chunks: [GOGContentChunk]
    /// Offset and size inside the depot's small-files container, when packed there.
    let containerSlice: (offset: Int64, size: Int64)?
    var size: Int64 { containerSlice?.size ?? chunks.reduce(0) { $0 + $1.size } }
}

struct GOGContentPlan {
    let installDirectory: String
    var files: [GOGContentFile] = []
    var directories: [String] = []
    /// Small-files containers, one per depot that has one.
    var containers: [(id: String, productID: String, chunks: [GOGContentChunk])] = []
    var containerOf: [String: String] = [:]   // file path -> container id
    var dependencies: [String] = []

    var downloadBytes: Int64 {
        files.filter { containerOf[$0.path] == nil }.flatMap(\.chunks).reduce(0) { $0 + $1.compressedSize }
            + containers.flatMap(\.chunks).reduce(0) { $0 + $1.compressedSize }
    }
    var installBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum GOGContentSystem {
    static let metaBase = "https://gog-cdn-fastly.gog.com/content-system/v2/meta/"

    // GOG secure_link returns a signed URL template plus its parameters.
    // The path must be normalized only once: double slashes in a signed CDN
    // store URL may return HTTP 404 even though the chunk exists.
    static func signedChunkURL(format: String, parameters: [String: String], hash: String) -> URL? {
        guard hash.count == 32, hash.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }) else { return nil }
        var values = parameters
        let base = (values["path"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = galaxyPath(hash)
        values["path"] = "/" + (base.isEmpty ? suffix : base + "/" + suffix)
        var text = format.replacingOccurrences(of: "\\/", with: "/")
        for (name, value) in values {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard !text.contains("{"), !text.contains("}"),
              let url = URL(string: text), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func galaxyPath(_ hash: String) -> String {
        guard hash.count > 4 else { return hash }
        let a = hash.prefix(2), b = hash.dropFirst(2).prefix(2)
        return "\(a)/\(b)/\(hash)"
    }

    /// zlib (RFC 1950) or plain data. NSData's .zlib is raw deflate, so the
    /// two-byte zlib header is skipped.
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 2, data[data.startIndex] == 0x78 else { return data }
        return try (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data
    }

    private static func get(_ url: URL, tokens: GOGTokens?) async throws -> Data {
        var request = URLRequest(url: url)
        if let tokens { request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization") }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await GOGAPI.session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw status == 401 ? GOGError.notSignedIn : GOGError.http(status) }
                return data
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where attempt < 5 {
                try Task.checkCancellation()
                attempt += 1
                AppLog.record("[gog] request interrupted (\(error.code.rawValue)); retry \(attempt)/5")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: inflate(data)) as? [String: Any] else {
            throw GOGContentError.invalidManifest
        }
        return object
    }

    private static func string(_ value: Any?) -> String? {
        value as? String ?? (value as? Int).map(String.init) ?? (value as? Int64).map(String.init)
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? Int64) ?? (value as? Int).map(Int64.init) ?? (value as? Double).map(Int64.init) ?? 0
    }

    /// The language codes GOG's depots use, best first ("pt-BR", "pt", "en-US", "en").
    static func preferredLanguages() -> [String] {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.language.region?.identifier
        var result: [String] = []
        if let region { result.append("\(code)-\(region)") }
        result.append(code)
        result += ["en-US", "en"]
        return result.map { $0.lowercased() }
    }

    /// Reads the newest public Windows build and lists every file to install.
    static func plan(gameID: Int, tokens: GOGTokens) async throws -> GOGContentPlan {
        let buildsURL = URL(string: "https://content-system.gog.com/products/\(gameID)/os/windows/builds?generation=2")!
        let builds = try json(try await get(buildsURL, tokens: tokens))
        let items = (builds["items"] as? [[String: Any]]) ?? []
        guard let build = items.first(where: { int64($0["generation"]) == 2 && ($0["branch"] == nil || $0["branch"] is NSNull) })
                ?? items.first(where: { int64($0["generation"]) == 2 }),
              let link = build["link"] as? String, let linkURL = URL(string: link) else { throw GOGContentError.noBuild }
        let manifest = try json(try await get(linkURL, tokens: tokens))
        guard let installDirectory = manifest["installDirectory"] as? String, !installDirectory.isEmpty else {
            throw GOGContentError.invalidManifest
        }
        let base = string(manifest["baseProductId"]) ?? String(gameID)
        let products: Set<String> = [String(gameID), base]
        let wanted = preferredLanguages()
        var depots = ((manifest["depots"] as? [[String: Any]]) ?? []).filter { products.contains(string($0["productId"]) ?? "") }
        // Language-neutral depots, plus the files of the best language offered.
        let languages = Set(depots.flatMap { ($0["languages"] as? [String] ?? []).map { $0.lowercased() } }).subtracting(["*"])
        let language = wanted.first(where: languages.contains)
            ?? wanted.compactMap { w in languages.first { $0.hasPrefix(w.prefix(2)) } }.first
            ?? languages.sorted().first
        depots = depots.filter { depot in
            let list = (depot["languages"] as? [String] ?? ["*"]).map { $0.lowercased() }
            return list.contains("*") || (language.map(list.contains) ?? false)
        }
        if let offline = manifest["offlineDepot"] as? [String: Any] { depots.append(offline) }
        guard !depots.isEmpty else { throw GOGContentError.noDepots }

        var plan = GOGContentPlan(installDirectory: installDirectory)
        plan.dependencies = manifest["dependencies"] as? [String] ?? []
        var seen = Set<String>()
        for depot in depots {
            guard let hash = depot["manifest"] as? String else { continue }
            let product = string(depot["productId"]) ?? base
            let meta = try json(try await get(URL(string: metaBase + galaxyPath(hash))!, tokens: nil))
            guard let body = meta["depot"] as? [String: Any] else { throw GOGContentError.invalidManifest }
            var containerID: String?
            if let sfc = body["smallFilesContainer"] as? [String: Any] {
                let chunks = parseChunks(sfc["chunks"])
                if !chunks.isEmpty {
                    containerID = hash
                    plan.containers.append((id: hash, productID: product, chunks: chunks))
                }
            }
            for item in (body["items"] as? [[String: Any]]) ?? [] {
                guard let raw = item["path"] as? String, let path = safePath(raw) else { continue }
                switch item["type"] as? String {
                case "DepotDirectory":
                    plan.directories.append(path)
                case "DepotFile":
                    guard seen.insert(path.lowercased()).inserted else { continue }
                    var slice: (Int64, Int64)?
                    if let ref = item["sfcRef"] as? [String: Any], containerID != nil {
                        slice = (int64(ref["offset"]), int64(ref["size"]))
                    }
                    plan.files.append(GOGContentFile(path: path, productID: product,
                                                     chunks: parseChunks(item["chunks"]), containerSlice: slice))
                    if slice != nil, let containerID { plan.containerOf[path] = containerID }
                default:
                    continue // DepotLink: symbolic links are for macOS builds
                }
            }
        }
        guard !plan.files.isEmpty else { throw GOGContentError.noDepots }
        return plan
    }

    private static func parseChunks(_ value: Any?) -> [GOGContentChunk] {
        ((value as? [[String: Any]]) ?? []).compactMap { chunk in
            guard let md5 = chunk["md5"] as? String, let compressed = chunk["compressedMd5"] as? String else { return nil }
            return GOGContentChunk(md5: md5, compressedMd5: compressed, size: int64(chunk["size"]),
                                   compressedSize: int64(chunk["compressedSize"]))
        }
    }

    /// A relative path without "..", absolute roots or empty parts.
    static func safePath(_ raw: String) -> String? {
        let parts = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.joined(separator: "/")
    }
}

/// Downloads a plan into a folder. Files already complete (right size) are kept,
/// so a cancelled or failed install resumes where it stopped.
final class GOGContentInstaller: @unchecked Sendable {
    private let tokens: GOGTokens
    private let progress: @Sendable (Int64) -> Void
    private struct SignedCDN: Sendable {
        let format: String
        let parameters: [String: String]
    }

    private actor SecureLinkCache {
        struct Entry: Sendable {
            let providers: [SignedCDN]
            let fetched: Date
        }
        private var values: [String: Entry] = [:]
        func entry(for productID: String) -> Entry? { values[productID] }
        func store(_ entry: Entry, for productID: String) { values[productID] = entry }
    }
    private let linkCache = SecureLinkCache()

    init(tokens: GOGTokens, progress: @escaping @Sendable (Int64) -> Void) {
        self.tokens = tokens
        self.progress = progress
    }

    func install(_ plan: GOGContentPlan, into folder: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for directory in plan.directories {
            try manager.createDirectory(at: folder.appendingPathComponent(directory), withIntermediateDirectories: true)
        }

        // Small files packed in a container: fetch the container, then cut the files out.
        for container in plan.containers {
            let members = plan.files.filter { plan.containerOf[$0.path] == container.id }
            if members.allSatisfy({ isComplete($0, in: folder) }) {
                progress(container.chunks.reduce(0) { $0 + $1.compressedSize })
                continue
            }
            let blob = folder.appendingPathComponent(".ideck-sfc-\(container.id)")
            try await assemble(container.chunks, productID: container.productID, to: blob, label: "small files")
            let reader = try FileHandle(forReadingFrom: blob)
            defer { try? reader.close(); try? manager.removeItem(at: blob) }
            for file in members {
                guard let slice = file.containerSlice else { continue }
                try reader.seek(toOffset: UInt64(slice.offset))
                let data = try reader.read(upToCount: Int(slice.size)) ?? Data()
                let target = folder.appendingPathComponent(file.path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        }

        // Every other file, four at a time.
        let files = plan.files.filter { plan.containerOf[$0.path] == nil }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < files.count else { return }
                let file = files[next]
                next += 1
                group.addTask { try await self.download(file, into: folder) }
            }
            for _ in 0..<4 { add() }
            while try await group.next() != nil {
                try Task.checkCancellation()
                add()
            }
        }
    }

    private func isComplete(_ file: GOGContentFile, in folder: URL) -> Bool {
        let path = folder.appendingPathComponent(file.path).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return false }
        return size == file.size
    }

    private func download(_ file: GOGContentFile, into folder: URL) async throws {
        let target = folder.appendingPathComponent(file.path)
        if isComplete(file, in: folder) {
            progress(file.chunks.reduce(0) { $0 + $1.compressedSize })
            return
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await assemble(file.chunks, productID: file.productID, to: target, label: file.path)
    }

    /// Downloads, inflates and checks each chunk, appending it to `target`.
    private func assemble(_ chunks: [GOGContentChunk], productID: String, to target: URL, label: String) async throws {
        let manager = FileManager.default
        let partial = target.appendingPathExtension("ideck-part")
        try? manager.removeItem(at: partial)
        manager.createFile(atPath: partial.path, contents: nil)
        let writer = try FileHandle(forWritingTo: partial)
        do {
            for chunk in chunks {
                try Task.checkCancellation()
                let data = try await fetchChunk(chunk, productID: productID, label: label)
                try writer.write(contentsOf: data)
                progress(chunk.compressedSize)
            }
            try writer.close()
        } catch {
            try? writer.close()
            try? manager.removeItem(at: partial)
            throw error
        }
        try? manager.removeItem(at: target)
        try manager.moveItem(at: partial, to: target)
    }

    private func fetchChunk(_ chunk: GOGContentChunk, productID: String, label: String) async throws -> Data {
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                let url = try await chunkURL(chunk.compressedMd5, productID: productID, attempt: attempt)
                let (data, response) = try await GOGAPI.session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw status == 401 ? GOGError.notSignedIn : GOGError.http(status) }
                // Check the *compressed* checksum before inflating. Each GOG
                // content-system chunk has both hashes in its depot manifest.
                guard Self.md5(data) == chunk.compressedMd5.lowercased() else {
                    throw GOGContentError.checksum(label)
                }
                let inflated = try GOGContentSystem.inflate(data)
                guard Self.md5(inflated) == chunk.md5.lowercased() else { throw GOGContentError.checksum(label) }
                return inflated
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                // URLSession translates task-group cancellation into -999.
                // It is never a CDN failure, and must not be retried.
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if case GOGError.notSignedIn = error { throw error }
                attempt += 1
                guard attempt <= 5 else { throw error }
                AppLog.record("[gog] chunk of \(label) failed (\(error.localizedDescription)); retry \(attempt)/5 with refreshed or alternate CDN")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Obtain signed links from the official GOG content system. Rotate all
    /// returned CDN providers before renewing a token. Never log signed URLs
    /// or bearer credentials; links are scoped to each product ID.
    private func chunkURL(_ hash: String, productID: String, attempt: Int) async throws -> URL {
        var saved = await linkCache.entry(for: productID)
        let expired = saved.map { Date().timeIntervalSince($0.fetched) > 600 } ?? true
        let exhausted = attempt > 0 && (saved?.providers.isEmpty != false ||
                                         attempt % max(1, saved?.providers.count ?? 1) == 0)
        if expired || exhausted {
            let url = URL(string: "https://content-system.gog.com/products/\(productID)/secure_link?generation=2&path=/&_version=2")!
            var request = URLRequest(url: url)
            request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
            let (data, response) = try await GOGAPI.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw status == 401 ? GOGError.notSignedIn : GOGError.http(status) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urls = json["urls"] as? [[String: Any]] else {
                throw GOGContentError.invalidManifest
            }
            let providers: [SignedCDN] = urls.compactMap { item in
                guard let format = item["url_format"] as? String,
                      let raw = item["parameters"] as? [String: Any] else { return nil }
                var parameters: [String: String] = [:]
                for (key, value) in raw { parameters[key] = String(describing: value) }
                // Reject malformed and non-HTTPS templates before caching.
                guard GOGContentSystem.signedChunkURL(
                    format: format, parameters: parameters, hash: hash) != nil else { return nil }
                return SignedCDN(format: format, parameters: parameters)
            }
            guard !providers.isEmpty else { throw GOGContentError.invalidManifest }
            let entry = SecureLinkCache.Entry(providers: providers, fetched: Date())
            await linkCache.store(entry, for: productID)
            saved = entry
        }
        guard let choices = saved?.providers, !choices.isEmpty else {
            throw GOGContentError.invalidManifest
        }
        let server = choices[attempt % choices.count]
        guard let url = GOGContentSystem.signedChunkURL(
            format: server.format, parameters: server.parameters, hash: hash) else {
            throw GOGContentError.invalidManifest
        }
        return url
    }
}
