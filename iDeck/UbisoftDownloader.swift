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
    /// The built-in value is the one iDeck was written against; 2.15.0's log shows the
    /// server ending the connection right after it (TLS 1.2 connected, then "the
    /// server ended the connection" with no answer), as for a client it no longer
    /// accepts. The Ubisoft Connect iDeck installs in the prefix carries the current
    /// number, so that one is sent when it is newer.
    static let builtInClientVersion: UInt64 = 10931

    static var clientVersion: UInt64 {
        let drive = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c")
        var candidates: [URL] = []
        for folder in ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher", "Program Files/Ubisoft/Ubisoft Game Launcher"] {
            for name in ["upc.exe", "UbisoftConnect.exe", "uplay_r1_loader64.dll", "UplayService.exe"] {
                candidates.append(drive.appendingPathComponent(folder).appendingPathComponent(name))
            }
        }
        // The official installer iDeck downloaded carries the same version resource.
        candidates.append(drive.appendingPathComponent("iDeck/UbisoftConnectInstaller.exe"))
        var seen: [String] = []
        for url in candidates {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  let version = EAPEVersion.productVersion(data) else { continue }
            seen.append("\(url.lastPathComponent) \(version.major).\(version.minor).\(version.patch).\(version.build)")
            // The build number is the 3rd or the 4th field, depending on the file.
            for field in [version.patch, version.build] {
                let build = UInt64(field)
                if build > builtInClientVersion && build < 100_000 {
                    AppLog.record("[ubisoft-demux] version resources: " + seen.joined(separator: ", "))
                    return build
                }
            }
        }
        AppLog.record("[ubisoft-demux] version resources: " + (seen.isEmpty ? "none found" : seen.joined(separator: ", ")))
        return builtInClientVersion
    }

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
        let clientVersion = Self.clientVersion
        AppLog.record("[ubisoft-demux] client version \(clientVersion)"
                      + (clientVersion == Self.builtInClientVersion ? " (built in)" : " (from the installed Ubisoft Connect)"))
        var version = GalaxyProto.Writer(); version.uint(1, clientVersion)
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
                if complete {
                    // Whether anything came back first tells a refused client (nothing)
                    // from a session the server ended later.
                    AppLog.record("[ubisoft-demux] the server ended the connection; frames left unread: \(self.buffer.count) byte(s), requests waiting: \(self.waiting.count + self.serviceWaiting.count)")
                    self.fail(UbisoftDemuxError.closed("the server ended the connection")); return
                }
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

