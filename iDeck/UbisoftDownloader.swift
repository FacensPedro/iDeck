import Foundation
import Network

// Ubisoft Connect's own way of installing games, without the launcher: the
// "demux" service (dmx.upc.ubisoft.com:443, TLS) answers with the games the
// account owns and their newest manifest, an ownership token per game, and
// signed CDN addresses for the manifest and its slices. Message layouts follow
// the protobuf definitions Ubisoft Connect ships (upc.exe), as published by
// UplayDB/Protobufs, and the flow of YoobieRE/ubisoft-manifest-downloader.
// Frames on the socket: a u32 big-endian length, then a demux Upstream or
// Downstream message. A service connection's messages travel inside demux
// DataMessage pushes, each again prefixed by its u32 big-endian length.

enum UbisoftDemuxError: LocalizedError {
    case closed(String)
    case refused(String)
    case timeout(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .closed(let why): return tr("Ubisoft's download service closed the connection (%@).", why)
        case .refused(let what): return tr("Ubisoft refused the request: %@.", what)
        case .timeout(let what): return tr("Ubisoft's download service did not answer (%@).", what)
        case .malformed(let what): return tr("Ubisoft sent an answer iDeck cannot read (%@).", what)
        }
    }
}

/// One connection to Ubisoft's demux service.
final class UbisoftDemux: @unchecked Sendable {
    static let host = "dmx.upc.ubisoft.com"
    /// The launcher version sent first on every socket (upc.exe's file version build).
    static let clientVersion: UInt64 = 10931

    private let queue = DispatchQueue(label: "ideck.ubisoft.demux")
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var nextRequestID: UInt32 = 1
    private var nextServiceRequestID: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<GalaxyFields, Error>] = [:]
    private var serviceWaiting: [String: CheckedContinuation<GalaxyFields, Error>] = [:]
    private var failure: Error?

    deinit { connection?.cancel() }

    func close() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
            fail(UbisoftDemuxError.closed("closed"))
        }
    }

    // MARK: Socket

    /// Opens the TLS connection to the demux, twice at most: the second time over IPv4
    /// only. Every state the connection passes through goes to iDeck's log
    /// ([ubisoft-demux]), with the reason when it waits or fails: 2.13.2 only said
    /// "did not answer (connection)" after 20 s (iPad mini, 2026-11-23).
    func connect() async throws {
        var lastError: Error = UbisoftDemuxError.timeout("connection")
        var opened: NWConnection?
        // 2.14.1: the server closed the TLS handshake (errSSLClosedNoNotify, -9816) on an
        // iPad for both attempts of 2.14.0; attempts 2 and 3 offer TLS 1.2 only, the
        // version older Ubisoft Connect clients speak.
        for attempt in 1...3 {
            do {
                opened = try await open(ipv4Only: attempt == 3, tls12: attempt >= 2)
                break
            } catch {
                lastError = error
                AppLog.record("[ubisoft-demux] connection attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        guard let connection = opened else { throw lastError }
        queue.sync { self.connection = connection }
        receive()
        // The client version goes first, as a push.
        var version = GalaxyProto.Writer(); version.uint(1, Self.clientVersion)
        var push = GalaxyProto.Writer(); push.data(4, version.bytes)
        var upstream = GalaxyProto.Writer(); upstream.data(2, push.bytes)
        send(upstream.bytes)
    }

    private func open(ipv4Only: Bool, tls12: Bool = false) async throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        if tls12 {
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        }
        let parameters = NWParameters(tls: tls)
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(host: NWEndpoint.Host(Self.host), port: 443, using: parameters)
        let label = (ipv4Only ? "IPv4" : "any") + (tls12 ? ", TLS 1.2" : "")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            var reason = "no answer"
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .preparing:
                    AppLog.record("[ubisoft-demux] connecting (\(label))")
                case .waiting(let error):
                    // DNS, no route, refused, TLS: why the connection is not ready yet.
                    reason = "waiting: \(error.localizedDescription)"
                    AppLog.record("[ubisoft-demux] \(reason) (\(label))")
                case .ready:
                    let path = connection.currentPath
                    let kind = path?.usesInterfaceType(.wifi) == true ? "Wi-Fi"
                        : path?.usesInterfaceType(.cellular) == true ? "cellular" : "other"
                    AppLog.record("[ubisoft-demux] connected (\(label), \(kind))")
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error):
                    AppLog.record("[ubisoft-demux] failed: \(error.localizedDescription) (\(label))")
                    // Before .ready only this attempt fails (the next one may succeed);
                    // after it, every waiting request does.
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    else { self?.queue.async { self?.fail(error) } }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(throwing: UbisoftDemuxError.closed("cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
            // A connection that never gets ready stays in .waiting: give up after 20 s,
            // with the last reason Network.framework gave.
            queue.asyncAfter(deadline: .now() + 20) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(throwing: UbisoftDemuxError.timeout("connection, \(reason)"))
            }
        }
        return connection
    }

    private func send(_ message: [UInt8]) {
        let length = UInt32(message.count)
        var frame = [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        frame += message
        queue.async { [self] in
            connection?.send(content: Data(frame), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.queue.async { self?.fail(error) }
            })
        }
    }

    private func receive() {
        queue.async { [self] in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer += data
                    self.drain()
                }
                if let error { self.fail(error); return }
                if complete { self.fail(UbisoftDemuxError.closed("the server ended the connection")); return }
                self.receive()
            }
        }
    }

    /// Splits the buffer into frames and hands each to the request waiting for it.
    private func drain() {
        while buffer.count >= 4 {
            let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
            guard buffer.count >= 4 + length else { return }
            let frame = Array(buffer[4..<4 + length])
            buffer.removeFirst(4 + length)
            guard let downstream = try? GalaxyFields(frame) else { continue }
            if let response = downstream.data(1), let rsp = try? GalaxyFields(response), let id = rsp.uint(1) {
                waiting.removeValue(forKey: UInt32(id))?.resume(returning: rsp)
            }
            if let pushBytes = downstream.data(2), let push = try? GalaxyFields(pushBytes) {
                if let dataBytes = push.data(1), let message = try? GalaxyFields(dataBytes),
                   let connectionID = message.uint(1), let payload = message.data(2), payload.count >= 4,
                   let inner = try? GalaxyFields(Array(payload[4...])),
                   let response = inner.data(1), let rsp = try? GalaxyFields(response) {
                    let id = rsp.uint(1) ?? 0
                    serviceWaiting.removeValue(forKey: "\(connectionID):\(id)")?.resume(returning: rsp)
                }
                if let closed = push.data(2), let fields = try? GalaxyFields(closed), let id = fields.uint(1) {
                    let reason = UbisoftDemuxError.closed("service connection \(id) closed, code \(fields.uint(2) ?? 0)")
                    for key in serviceWaiting.keys where key.hasPrefix("\(id):") {
                        serviceWaiting.removeValue(forKey: key)?.resume(throwing: reason)
                    }
                }
            }
        }
    }

    private func fail(_ error: Error) {
        failure = failure ?? error
        let pending = waiting.values.map { $0 } + serviceWaiting.values.map { $0 }
        waiting.removeAll()
        serviceWaiting.removeAll()
        for continuation in pending { continuation.resume(throwing: error) }
    }

    private func timeout(after seconds: Double, _ what: String, cancel: @escaping @Sendable () -> CheckedContinuation<GalaxyFields, Error>?) {
        queue.asyncAfter(deadline: .now() + seconds) {
            cancel()?.resume(throwing: UbisoftDemuxError.timeout(what))
        }
    }

    /// A demux-level request: `build` writes the Req's fields after its request_id.
    private func request(_ what: String, _ build: (inout GalaxyProto.Writer) -> Void) async throws -> GalaxyFields {
        var req = GalaxyProto.Writer()
        let id: UInt32 = queue.sync { defer { nextRequestID += 1 }; return nextRequestID }
        req.uint(1, UInt64(id))
        build(&req)
        var upstream = GalaxyProto.Writer(); upstream.data(1, req.bytes)
        let message = upstream.bytes
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { continuation.resume(throwing: failure); return }
                waiting[id] = continuation
                send(message)
                timeout(after: 30, what) { [weak self] in self?.waiting.removeValue(forKey: id) }
            }
        }
    }

    /// Logs in with the Ubisoft session ticket (the account's ubi_v1 ticket).
    func authenticate(ticket: String) async throws {
        let rsp = try await request("sign-in") { req in
            var token = GalaxyProto.Writer(); token.string(3, ticket)
            var auth = GalaxyProto.Writer()
            auth.data(1, token.bytes)
            auth.string(2, "uplay_pc")
            auth.bool(4, false)
            req.data(2, auth.bytes)
        }
        guard let bytes = rsp.data(2), let auth = try? GalaxyFields(bytes) else { throw UbisoftDemuxError.malformed("sign-in") }
        guard auth.bool(1) == true else {
            throw UbisoftDemuxError.refused(auth.bool(2) == true ? "the session expired, sign in to Ubisoft again" : "sign-in")
        }
    }

    /// Opens a service connection ("ownership_service", "download_service").
    func openConnection(_ service: String) async throws -> UInt32 {
        let rsp = try await request("open \(service)") { req in
            var open = GalaxyProto.Writer(); open.string(2, service)
            req.data(3, open.bytes)
        }
        guard let bytes = rsp.data(3), let open = try? GalaxyFields(bytes), let id = open.uint(1), id != 0,
              open.bool(2) != false else { throw UbisoftDemuxError.refused("open \(service)") }
        return UInt32(id)
    }

    /// A request on a service connection: `build` writes the service Req's fields
    /// after its request_id; returns the service Rsp's fields.
    func service(_ connectionID: UInt32, _ what: String, _ build: (inout GalaxyProto.Writer) -> Void) async throws -> GalaxyFields {
        let id: UInt32 = queue.sync { defer { nextServiceRequestID += 1 }; return nextServiceRequestID }
        var req = GalaxyProto.Writer()
        req.uint(1, UInt64(id))
        build(&req)
        var inner = GalaxyProto.Writer(); inner.data(1, req.bytes)
        let length = UInt32(inner.bytes.count)
        let payload = [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + inner.bytes
        var message = GalaxyProto.Writer(); message.uint(1, UInt64(connectionID)); message.data(2, payload)
        var push = GalaxyProto.Writer(); push.data(1, message.bytes)
        var upstream = GalaxyProto.Writer(); upstream.data(2, push.bytes)
        let frame = upstream.bytes
        let key = "\(connectionID):\(id)"
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let failure { continuation.resume(throwing: failure); return }
                serviceWaiting[key] = continuation
                send(frame)
                timeout(after: 60, what) { [weak self] in self?.serviceWaiting.removeValue(forKey: key) }
            }
        }
    }
}

/// A game the account owns, as the ownership service lists it.
struct UbisoftOwnedProduct: Equatable, Sendable {
    let productID: UInt32
    let name: String
    let manifest: String
    let productType: UInt64
}

/// The ownership and download services over one demux connection.
final class UbisoftContentClient: @unchecked Sendable {
    let demux = UbisoftDemux()
    private var ownership: UInt32?
    private var download: UInt32?
    private var downloadToken: (product: UInt32, until: Date)?

    static func signedIn() async throws -> UbisoftContentClient {
        guard let session = await UbisoftSavedSession.current() else {
            throw UbisoftDemuxError.refused(tr("sign in to Ubisoft in Settings › Stores & launchers › Ubisoft Connect"))
        }
        let client = UbisoftContentClient()
        try await client.demux.connect()
        try await client.demux.authenticate(ticket: session.ticket)
        return client
    }

    func close() { demux.close() }

    private func ownershipConnection() async throws -> UInt32 {
        if let ownership { return ownership }
        let id = try await demux.openConnection("ownership_service")
        ownership = id
        return id
    }

    /// The games the account owns that Ubisoft lets it download.
    func ownedGames() async throws -> [UbisoftOwnedProduct] {
        let connection = try await ownershipConnection()
        let rsp = try await demux.service(connection, "owned games") { req in
            var initialize = GalaxyProto.Writer()
            initialize.bool(2, true)      // get_associations
            initialize.uint(3, 7)         // proto_version
            initialize.bool(5, false)     // use_staging
            req.data(2, initialize.bytes)
        }
        guard let bytes = rsp.data(2), let initialize = try? GalaxyFields(bytes) else { throw UbisoftDemuxError.malformed("owned games") }
        guard initialize.bool(1) != false else { throw UbisoftDemuxError.refused("owned games") }
        guard let gamesBytes = initialize.data(2), let games = try? GalaxyFields(gamesBytes) else { return [] }
        var products: [UbisoftOwnedProduct] = []
        for (number, field) in games.fields where number == 1 {
            guard case let .bytes(raw) = field, let game = try? GalaxyFields(raw), let id = game.uint(1) else { continue }
            let manifest = game.string(21) ?? ""
            let configuration = game.string(17) ?? ""
            let name = UbisoftConfiguration.name(configuration) ?? ""
            products.append(UbisoftOwnedProduct(productID: UInt32(id), name: name, manifest: manifest,
                                                productType: game.uint(8) ?? 0))
        }
        return products
    }

    /// Signed CDN addresses for paths of a product ("manifests/<sha>.manifest", "slices_v3/...").
    func signedURLs(product: UInt32, paths: [String]) async throws -> [URL] {
        if download == nil || downloadToken?.product != product || (downloadToken?.until ?? .distantPast) < Date() {
            let ownership = try await ownershipConnection()
            let tokenRsp = try await demux.service(ownership, "ownership token") { req in
                var token = GalaxyProto.Writer(); token.uint(1, UInt64(product))
                req.data(28, token.bytes)
            }
            guard let bytes = tokenRsp.data(27), let fields = try? GalaxyFields(bytes), let token = fields.string(2), !token.isEmpty else {
                throw UbisoftDemuxError.refused("ownership token for product \(product)")
            }
            let connection: UInt32
            if let download { connection = download } else {
                connection = try await demux.openConnection("download_service")
                download = connection
            }
            let initRsp = try await demux.service(connection, "download service") { req in
                var initialize = GalaxyProto.Writer(); initialize.string(5, token)
                req.data(2, initialize.bytes)
            }
            guard let initBytes = initRsp.data(2), let ok = try? GalaxyFields(initBytes), ok.bool(1) == true else {
                throw UbisoftDemuxError.refused("download service for product \(product)")
            }
            // Tokens last minutes; renew a little before the end the service gives.
            let seconds = Double(fields.uint(3).map { $0 > 1_000_000_000 ? Double($0) - Date().timeIntervalSince1970 : Double($0) } ?? 600)
            downloadToken = (product, Date().addingTimeInterval(max(60, min(seconds, 3600)) - 30))
        }
        guard let connection = download else { throw UbisoftDemuxError.closed("download service") }
        let rsp = try await demux.service(connection, "download addresses") { req in
            var request = GalaxyProto.Writer()
            request.uint(1, UInt64(product))
            for path in paths { request.string(2, path) }
            var urlReq = GalaxyProto.Writer(); urlReq.data(1, request.bytes)
            req.data(3, urlReq.bytes)
        }
        guard let bytes = rsp.data(3), let urlRsp = try? GalaxyFields(bytes) else { throw UbisoftDemuxError.malformed("download addresses") }
        var urls: [URL] = []
        for (number, field) in urlRsp.fields where number == 1 {
            guard case let .bytes(raw) = field, let response = try? GalaxyFields(raw) else { continue }
            if let result = response.uint(1), result != 0 { throw UbisoftDemuxError.refused(tr("the account does not own this game")) }
            for (n, f) in response.fields where n == 2 {
                guard case let .bytes(rawURLs) = f, let list = try? GalaxyFields(rawURLs) else { continue }
                if let first = list.strings(1).first, let url = URL(string: first) { urls.append(url) }
            }
        }
        guard urls.count == paths.count else { throw UbisoftDemuxError.malformed("\(urls.count) of \(paths.count) addresses") }
        return urls
    }
}

/// The few things iDeck reads from a product's configuration (YAML text).
enum UbisoftConfiguration {
    /// root › name; a localized name ("l1") is looked up in localizations › default.
    static func name(_ yaml: String) -> String? {
        let lines = yaml.components(separatedBy: .newlines)
        var inRoot = false
        var raw: String?
        for line in lines {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { inRoot = line.hasPrefix("root:") ; continue }
            guard inRoot else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only root's own "name:", two spaces in.
            if line.hasPrefix("  name:") && !line.hasPrefix("   ") {
                raw = unquote(String(trimmed.dropFirst("name:".count)))
                break
            }
        }
        guard var name = raw, !name.isEmpty else { return nil }
        if name.range(of: "^l[0-9]+$", options: .regularExpression) != nil {
            var inLocalizations = false, inDefault = false
            for line in lines {
                if !line.hasPrefix(" ") { inLocalizations = line.hasPrefix("localizations:"); inDefault = false; continue }
                guard inLocalizations else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("  ") && !line.hasPrefix("   ") { inDefault = trimmed.hasPrefix("default:"); continue }
                if inDefault, trimmed.hasPrefix(name + ":") {
                    name = unquote(String(trimmed.dropFirst(name.count + 1)))
                    break
                }
            }
        }
        return name.isEmpty || name.range(of: "^l[0-9]+$", options: .regularExpression) != nil ? nil : name
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// A download manifest (mg.protocol.download.Manifest), only what installing needs.
struct UbisoftManifest: Sendable {
    struct Slice: Sendable { let hash: [UInt8]; let size: UInt64; let offset: UInt64? }
    struct File: Sendable { let name: String; let size: UInt64; let isDir: Bool; let slices: [Slice] }

    enum Compression: UInt64, Sendable { case none = 0, deflate = 1, lzham = 2, zstd = 3 }

    var files: [File] = []
    var compression: Compression = .none
    var languages: Set<String> = []

    var totalBytes: UInt64 { files.reduce(0) { $0 + ($1.isDir ? 0 : $1.size) } }

    /// The file as the CDN serves it: a 356-byte header, then the zlib-compressed message.
    static func parse(_ data: Data, language: String) throws -> UbisoftManifest {
        let bytes = [UInt8](data)
        var message: [UInt8]?
        for skip in [356, 0] where bytes.count > skip {
            if let inflated = UbisoftInflate.zlib(Array(bytes[skip...])) { message = inflated; break }
        }
        guard let message, let root = try? GalaxyFields(message) else { throw UbisoftDemuxError.malformed("manifest") }
        var manifest = UbisoftManifest()
        let compressed = root.bool(17) ?? true
        manifest.compression = compressed ? Compression(rawValue: root.uint(21) ?? 1) ?? .deflate : .none
        var chosen: [UbisoftManifest.File] = []
        for (number, field) in root.fields where number == 4 {
            guard case let .bytes(raw) = field, let chunk = try? GalaxyFields(raw) else { continue }
            let required = (chunk.uint(2) ?? 0) == 0
            let chunkLanguage = chunk.string(5) ?? ""
            if !chunkLanguage.isEmpty { manifest.languages.insert(chunkLanguage) }
            // Required chunks, and the language chunk for the chosen language.
            guard (required && chunkLanguage.isEmpty) || chunkLanguage.lowercased() == language.lowercased() else { continue }
            for (n, f) in chunk.fields where n == 3 {
                guard case let .bytes(fileRaw) = f, let file = try? GalaxyFields(fileRaw), let name = file.string(1) else { continue }
                let hashes = file.fields.compactMap { k, v -> [UInt8]? in if k == 4, case let .bytes(b) = v { return b } else { return nil } }
                let list = file.fields.compactMap { k, v -> GalaxyFields? in
                    if k == 7, case let .bytes(b) = v { return try? GalaxyFields(b) } else { return nil }
                }
                var slices: [Slice] = []
                if !list.isEmpty {
                    for (index, slice) in list.enumerated() {
                        guard let hash = slice.data(3) ?? (index < hashes.count ? hashes[index] : nil) else { continue }
                        slices.append(Slice(hash: hash, size: slice.uint(1) ?? 0, offset: slice.uint(4)))
                    }
                } else {
                    slices = hashes.map { Slice(hash: $0, size: 0, offset: nil) }
                }
                chosen.append(File(name: name.replacingOccurrences(of: "\\", with: "/"), size: file.uint(2) ?? 0,
                                   isDir: file.bool(3) ?? false, slices: slices))
            }
        }
        // A language-free install still needs a language when every chunk has one.
        if chosen.allSatisfy(\.isDir), language.lowercased() != "en-us" {
            return try parse(data, language: "en-US")
        }
        manifest.files = chosen
        return manifest
    }

    /// The CDN path of a slice: slices_v3/<one base-32 character>/<SHA1 in upper hex>.
    static func slicePath(_ hash: [UInt8]) -> String {
        let hex = hash.map { String(format: "%02X", $0) }.joined()
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
        let chars = Array(hex)
        guard chars.count >= 2, let value = UInt8(String([chars[1], chars[0]]), radix: 16) else { return "slices_v3/0/" + hex }
        let index = Int(value / 16) + (value % 2 == 0 ? 0 : 16)
        return "slices_v3/\(alphabet[index])/\(hex)"
    }
}

enum UbisoftInflate {
    /// zlib-wrapped or raw deflate data, inflated whole by the app's C codec
    /// (ZipNative.c). A zlib stream's 2-byte header is skipped; its Adler-32 is not checked.
    static func zlib(_ input: [UInt8], raw: Bool = false, expected: Int = 0) -> [UInt8]? {
        var body = input
        if !raw {
            guard input.count > 2, input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0,
                  input[1] & 0x20 == 0 else { return nil }
            body = Array(input[2...])
        }
        var capacity = expected > 0 ? expected : max(body.count * 8, 1 << 16)
        while capacity <= 1 << 28 {   // manifests are a few MB; stop well before memory runs out
            var output = [UInt8](repeating: 0, count: capacity)
            var produced = 0
            let result = body.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    ideck_zip_inflate_raw(src.baseAddress, src.count, dst.baseAddress, dst.count, &produced, nil)
                }
            }
            if result == Int32(IDECK_ZIP_OK) {
                output.removeSubrange(produced...)
                return output
            }
            // Too small an output (or a corrupt stream): a known size is final.
            if expected > 0 { return nil }
            capacity *= 4
        }
        return nil
    }

    static func zstd(_ input: [UInt8], expected: Int) -> [UInt8]? {
        guard expected > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: expected)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in zstd_safe_decompress(dst.baseAddress, expected, src.baseAddress, input.count) }
        }
        guard written >= 0, written <= expected else { return nil }   // (size_t)-1 is an error
        output.removeSubrange(written...)
        return output
    }

    /// LZHAM 1.x through the app's C++ codec (LzhamCodec.cpp, Vendor/LZHAM). Ubisoft
    /// writes slices as LZHAM zlib streams with a 2^15 dictionary (as UplayDB's
    /// UplayApps reads them); the codec takes the dictionary size from the stream's
    /// header and checks its Adler-32. Returns the bytes, or the codec's status on failure.
    static func lzham(_ input: [UInt8], expected: Int) -> Result<[UInt8], LzhamFailure> {
        var capacity = expected > 0 ? expected : max(input.count * 8, 1 << 20)
        while true {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    ideck_lzham_decompress(src.baseAddress, src.count, dst.baseAddress, dst.count, 15)
                }
            }
            if written >= 0 {
                output.removeSubrange(Int(written)...)
                return .success(output)
            }
            // Without a known size, a too-small buffer ends as DEST_BUF_TOO_SMALL (5) or,
            // in LZHAM's unbuffered mode, BAD_CODE (7): grow and try again.
            if written == -5 || written == -7, expected <= 0, capacity < 1 << 28 { capacity *= 4; continue }
            return .failure(LzhamFailure(status: Int(-written)))
        }
    }

    struct LzhamFailure: Error { let status: Int }
}

/// Installs a game from its manifest: downloads every slice, decompresses it and
/// writes it at its place in its file. Finished files are noted in a journal, so a
/// paused download resumes from the next file.
struct UbisoftInstaller {
    struct Progress: Sendable { var done: UInt64; var total: UInt64 }

    let client: UbisoftContentClient
    let product: UInt32
    let manifest: UbisoftManifest
    let folder: URL
    let journal: URL

    func run(progress: @escaping @Sendable (Progress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let finished = Set(((try? String(contentsOf: journal, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        var done: UInt64 = 0
        for file in manifest.files where finished.contains(file.name) { done += file.size }
        progress(Progress(done: done, total: manifest.totalBytes))
        for file in manifest.files {
            try Task.checkCancellation()
            let target = try destination(file.name)
            if file.isDir { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
            if finished.contains(file.name) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            // Slices of a file, a batch of addresses at a time, eight downloads at once.
            for batchStart in stride(from: 0, to: file.slices.count, by: 64) {
                let batch = Array(file.slices[batchStart..<min(batchStart + 64, file.slices.count)])
                let urls = try await client.signedURLs(product: product, paths: batch.map { UbisoftManifest.slicePath($0.hash) })
                for groupStart in stride(from: 0, to: batch.count, by: 8) {
                    try Task.checkCancellation()
                    let group = Array(groupStart..<min(groupStart + 8, batch.count))
                    let parts = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { tasks in
                        for index in group {
                            let slice = batch[index], url = urls[index], compression = manifest.compression
                            tasks.addTask {
                                let bytes = try await Self.fetch(url, slice: slice, compression: compression)
                                return (index, bytes)
                            }
                        }
                        var out: [Int: [UInt8]] = [:]
                        for try await (index, bytes) in tasks { out[index] = bytes }
                        return out
                    }
                    for index in group {
                        guard let bytes = parts[index] else { continue }
                        let at = batch[index].offset ?? offset
                        try handle.seek(toOffset: at)
                        try handle.write(contentsOf: bytes)
                        offset = at + UInt64(bytes.count)
                        done += UInt64(bytes.count)
                        progress(Progress(done: min(done, manifest.totalBytes), total: manifest.totalBytes))
                    }
                }
            }
            try handle.truncate(atOffset: file.size)
            try (file.name + "\n").appendLine(to: journal)
        }
    }

    /// The file's place in the game folder; a name that leaves the folder is refused.
    private func destination(_ name: String) throws -> URL {
        let parts = name.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { throw UbisoftDemuxError.malformed("file name \(name)") }
        return parts.reduce(folder) { $0.appendingPathComponent($1) }
    }

    static func fetch(_ url: URL, slice: UbisoftManifest.Slice, compression: UbisoftManifest.Compression) async throws -> [UInt8] {
        var lastError: Error = UbisoftDemuxError.malformed("slice")
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw UbisoftDemuxError.refused("slice HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                let raw = [UInt8](data)
                let expected = Int(slice.size)
                switch compression {
                case .none: return raw
                case .zstd:
                    guard let out = UbisoftInflate.zstd(raw, expected: expected > 0 ? expected : max(raw.count * 8, 1 << 20)) else {
                        throw UbisoftDemuxError.malformed("zstd slice")
                    }
                    return out
                case .deflate:
                    guard let out = UbisoftInflate.zlib(raw, expected: expected) ?? UbisoftInflate.zlib(raw, raw: true, expected: expected) else {
                        throw UbisoftDemuxError.malformed("deflate slice")
                    }
                    return out
                case .lzham:
                    switch UbisoftInflate.lzham(raw, expected: expected) {
                    case .success(let out): return out
                    case .failure(let failure):
                        AppLog.record("[ubisoft-download] LZHAM slice failed: status \(failure.status), \(raw.count) bytes in, \(expected) expected")
                        throw UbisoftDemuxError.malformed("LZHAM slice")
                    }
                }
            } catch let error as UbisoftDemuxError {
                if case .malformed = error { throw error }
                lastError = error
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
        }
        throw lastError
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

extension UbisoftSavedSession {
    /// The saved session, renewed with its remember-me ticket when it has expired.
    static func current() async -> UbisoftSavedSession? {
        guard let saved = load() else { return nil }
        guard saved.expired else { return saved }
        guard let remember = saved.remember, !remember.isEmpty else { return nil }
        var login = request(appID: saved.appIDUsed ?? appIDs[0])
        login.setValue("ubi_rm_v1 t=" + remember, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: login),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let renewed = try? decode(data, previous: saved) else { return nil }
        try? renewed.save()
        return renewed
    }
}
