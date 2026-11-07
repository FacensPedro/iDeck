import Foundation
import Network
import SwiftUI
import UIKit

/// iRelay (github.com/FacensPedro/iRelay): a Windows program on the same local
/// network as this iPad (Wi-Fi or Ethernet). It works two ways:
///
/// 1. Games installed on the PC (Steam, GOG, Epic) are copied into iDeck's own
///    folders (`IRelayDeviceService`, port 27093): iRelay lists iDeck's
///    libraries, compares files and sends what is missing.
/// 2. While iDeck itself downloads a Steam game, iRelay downloads the same
///    chunks on the PC and hands each one over as it arrives (`IRelayClient`,
///    through `IRelayTunnel`):
///    - `GET /ping`
///    - `POST /jobs`: the chunks iDeck still needs, per depot, in order, with
///      the content servers and their authorization.
///    - `GET /depot/<id>/chunk/<sha>`: one chunk as a content server sends it,
///      checked and decrypted here like a content server's answer.
///
/// Only a PC that knows this iPad's pairing code (Settings › iRelay) is accepted.
enum IRelaySetting {
    /// iRelay connects by itself: nothing to turn on.
    static var enabled: Bool { true }
}

enum IRelayError: LocalizedError {
    case status(Int), notConnected

    var errorDescription: String? {
        switch self {
        case .status(let code): return "iRelay answered HTTP \(code)."
        case .notConnected: return "iRelay is not connected on the local network."
        }
    }
}

/// One iRelay for one install. Thread-safe; after repeated failures it turns
/// itself off and the install continues from Steam's content servers.
final class IRelayClient: @unchecked Sendable {
    struct Info: Decodable, Sendable { let name: String; let version: Int; let machine: String? }

    struct JobDepot: Encodable, Sendable {
        let depotId: UInt32
        let hosts: [String]
        let auth: [String: String]
        let chunks: [String]
    }

    let base = URL(string: "http://127.0.0.1:\(IRelayTunnel.localPort)")!
    private let lock = NSLock()
    private var failureCount = 0
    private var chunkCount = 0
    private var byteCount = 0
    private(set) var name = "iRelay"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The iRelay on the cable, when it is turned on in Settings.
    static func configured() -> IRelayClient? {
        IRelayTunnel.shared.start()
        // Only when iRelay keeps connections open over the cable: a download
        // without a PC never waits for one.
        return IRelayTunnel.shared.pcConnected ? IRelayClient() : nil
    }

    var usable: Bool { lock.withLock { failureCount < 5 } }
    var chunks: Int { lock.withLock { chunkCount } }
    var bytes: Int { lock.withLock { byteCount } }
    var failures: Int { lock.withLock { failureCount } }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 90) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw IRelayError.status(status) }
    }

    func ping() async throws -> Info {
        do {
            let (data, response) = try await Self.session.data(for: request("ping", timeout: 10))
            try Self.check(response)
            let info = try JSONDecoder().decode(Info.self, from: data)
            lock.withLock { name = info.machine.map { "iRelay (\($0))" } ?? info.name }
            return info
        } catch {
            if !IRelayTunnel.shared.pcConnected { throw IRelayError.notConnected }
            throw error
        }
    }

    /// Hands iRelay the whole list so the PC downloads ahead of this device.
    func startJob(appID: UInt32, title: String, depots: [JobDepot]) async throws {
        struct Job: Encodable { let appId: UInt32; let name: String; let depots: [JobDepot] }
        let body = try JSONEncoder().encode(Job(appId: appID, name: title, depots: depots))
        let (_, response) = try await Self.session.data(for: request("jobs", method: "POST", body: body, timeout: 30))
        try Self.check(response)
    }

    /// One chunk as a content server sends it.
    func chunk(depotID: UInt32, shaHex: String) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request("depot/\(depotID)/chunk/\(shaHex)"))
        try Self.check(response)
        return data
    }

    // MARK: Processing on the PC

    struct ProcessChunk: Encodable, Sendable { let sha: String; let offset: UInt64; let size: UInt32; let compressed: UInt32; let crc: UInt32 }
    struct ProcessFile: Encodable, Sendable { let path: String; let size: UInt64; var chunks: [ProcessChunk] }
    struct ProcessDepot: Encodable, Sendable {
        let depotId: UInt32
        let key: String
        let hosts: [String]
        let auth: [String: String]
        /// The install folder, relative to drive_c.
        let root: String
        let files: [ProcessFile]
    }
    struct ProcessStatus: Decodable, Sendable {
        var finished = false
        var chunksDone = 0
        var bytesDone: UInt64 = 0
        var compressedDone: UInt64 = 0
        var failed: [String] = []
    }

    /// iRelay downloads, decrypts, decompresses and checks these chunks and
    /// writes them into this device's files. Returns the job's ID.
    func startProcess(appID: UInt32, title: String, depots: [ProcessDepot]) async throws -> String {
        struct Job: Encodable { let appId: UInt32; let name: String; let depots: [ProcessDepot] }
        struct Started: Decodable { let id: String }
        let body = try JSONEncoder().encode(Job(appId: appID, name: title, depots: depots))
        let (data, response) = try await Self.session.data(for: request("process", method: "POST", body: body, timeout: 60))
        try Self.check(response)
        return try JSONDecoder().decode(Started.self, from: data).id
    }

    func processStatus(_ id: String) async throws -> ProcessStatus {
        let (data, response) = try await Self.session.data(for: request("process/\(id)", timeout: 20))
        try Self.check(response)
        return try JSONDecoder().decode(ProcessStatus.self, from: data)
    }

    func cancelProcess(_ id: String) async {
        _ = try? await Self.session.data(for: request("process/\(id)", method: "DELETE", timeout: 10))
    }

    /// Let the connected PC measure HTTPS round-trip latency for approved CDN
    /// hosts. Keep the original signed URLs, query strings and fallback order
    /// on the device; only bare HTTPS origins are sent to iRelay.
    static func rankedCDNURLs(store: String, urls: [URL]) async -> [URL] {
        guard urls.count > 1, let relay = configured() else { return urls }
        let origins = urls.compactMap { url -> String? in
            guard url.scheme?.lowercased() == "https", let host = url.host,
                  url.port == nil else { return nil }
            return "https://\(host.lowercased())"
        }
        guard origins.count == urls.count else { return urls }
        do {
            struct Request: Encodable { let store: String; let urls: [String] }
            struct Response: Decodable { let urls: [String] }
            let payload = try JSONEncoder().encode(Request(store: store, urls: origins))
            let (data, response) = try await Self.session.data(
                for: relay.request("servers/rank", method: "POST", body: payload, timeout: 8))
            try Self.check(response)
            let ranked = try JSONDecoder().decode(Response.self, from: data).urls
            var priorities: [String: Int] = [:]
            for (index, origin) in ranked.enumerated() where priorities[origin] == nil {
                priorities[origin] = index
            }
            return urls.enumerated().sorted { left, right in
                let a = priorities[origins[left.offset]] ?? (urls.count + left.offset)
                let b = priorities[origins[right.offset]] ?? (urls.count + right.offset)
                return a == b ? left.offset < right.offset : a < b
            }.map(\.element)
        } catch {
            return urls
        }
    }

    func recordSuccess(bytes: Int) {
        lock.withLock { chunkCount += 1; byteCount += bytes; failureCount = 0 }
    }

    /// True when this failure turned iRelay off for the install.
    @discardableResult func recordFailure() -> Bool {
        lock.withLock { failureCount += 1; return failureCount == 5 }
    }
}

/// Settings › iRelay: what to type in iRelay on the PC (this iPad's address and
/// pairing code) and the connection's state.
struct IRelaySettingsSection: View {
    @State private var status: String?
    @State private var testing = false
    @State private var code = IRelayPairing.display
    @State private var addresses = IRelayPairing.localAddresses()

    var body: some View {
        Section {
            LabeledContent(tr("iPad address"),
                           value: addresses.isEmpty ? tr("Connect to Wi-Fi") : addresses.joined(separator: ", "))
            LabeledContent(tr("Pairing code")) {
                Text(code).font(.body.monospaced().weight(.semibold)).textSelection(.enabled)
            }
            Button(tr("Refresh connection")) { refresh() }
            Button(tr("New pairing code")) {
                IRelayPairing.regenerate()
                code = IRelayPairing.display
            }
        } header: {
            Text("iRelay")
        }
        Section {
            Button(testing ? tr("Connecting…") : tr("Test connection")) { test() }
                .disabled(testing)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        IRelayRuntime.start()
        IRelayTunnel.shared.restartIfStopped()
        IRelayDeviceService.shared.restartIfStopped()
        addresses = IRelayPairing.localAddresses()
    }

    private func test() {
        refresh()
        testing = true
        status = nil
        Task {
            do {
                let info = try await IRelayClient().ping()
                status = tr("Connected to %@ (version %d).", info.machine ?? info.name, info.version)
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}

/// Starts everything iRelay needs on this device.
enum IRelayRuntime {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard IRelaySetting.enabled else { return }
        IRelayTunnel.shared.start()
        IRelayDeviceService.shared.start()
        IRelayPairing.requestLocalNetworkAccess()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                IRelayTunnel.shared.restartIfStopped()
                IRelayDeviceService.shared.restartIfStopped()
            }
        }
    }
}

// MARK: - Local network tunnel

/// iRelay over the local network, with the direction reversed so the PC needs
/// no open firewall port:
///
/// - iRelay keeps a few connections open to this device's port 27091 (`pcPort`).
///   Each starts with `IRELAY <pairing code>\n`; accepted ones wait in a pool.
/// - iDeck's own requests go to 127.0.0.1:27092 (`localPort`); each accepted
///   connection is joined to one waiting cable connection and bytes are copied
///   both ways. iRelay joins its end to its HTTP server, so the same requests
///   (`IRelayClient`) work over the cable unchanged.
final class IRelayTunnel: @unchecked Sendable {
    static let shared = IRelayTunnel()
    static let pcPort: UInt16 = 27091
    static let localPort: UInt16 = 27092

    private let queue = DispatchQueue(label: "ideck.irelay.tunnel")
    private var pcListener: NWListener?
    private var localListener: NWListener?
    private var pool: [NWConnection] = []
    private var waiting: [(NWConnection, DispatchWorkItem)] = []

    /// Whether iRelay has connections waiting on the local network.
    var pcConnected: Bool { queue.sync { pool.contains { if case .ready = $0.state { return true }; return false } } }

    /// Starts both listeners once; safe to call again.
    func start() {
        queue.sync {
            guard pcListener == nil && localListener == nil else { return }
            pcListener = makeListener(port: Self.pcPort) { [weak self] connection in self?.addPC(connection) }
            localListener = makeListener(port: Self.localPort) { [weak self] connection in self?.addLocal(connection) }
        }
    }

    private func makeListener(port: UInt16, accept: @escaping (NWConnection) -> Void) -> NWListener? {
        // The PC's port is on the local network; iDeck's own port stays on loopback.
        let parameters = IRelayPairing.localNetworkParameters()
        if port == Self.localPort { parameters.requiredInterfaceType = .loopback }
        guard let port = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: port) else {
            AppLog.record("[irelay-lan] could not listen on port \(port)")
            return nil
        }
        listener.newConnectionHandler = accept
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                AppLog.record("[irelay-lan] listener \(port) failed: \(error)")
                self?.queue.async { self?.restart() }
            }
        }
        listener.start(queue: queue)
        return listener
    }

    /// After iDeck returns to the foreground: listeners iOS stopped while the
    /// app was suspended are created again.
    func restartIfStopped() {
        queue.async { [self] in
            let stopped = [pcListener, localListener].contains { listener in
                guard let listener else { return true }
                switch listener.state {
                case .failed, .cancelled: return true
                default: return false
                }
            }
            guard stopped else { return }
            AppLog.record("[irelay-lan] listeners restarted after returning to the foreground")
            restart()
        }
    }

    private func restart() {
        pcListener?.cancel(); localListener?.cancel()
        pool.forEach { $0.cancel() }
        pool.removeAll()
        waiting.forEach { local, timeout in timeout.cancel(); local.cancel() }
        waiting.removeAll()
        pcListener = nil; localListener = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard self.pcListener == nil && self.localListener == nil else { return }
            self.pcListener = self.makeListener(port: Self.pcPort) { [weak self] c in self?.addPC(c) }
            self.localListener = self.makeListener(port: Self.localPort) { [weak self] c in self?.addLocal(c) }
        }
    }

    /// `IRELAY <code>\n`: 12 bytes the PC sends first on each connection.
    private static let preambleLength = 7 + IRelayPairing.digits + 1

    private func addPC(_ connection: NWConnection) {
        connection.start(queue: queue)
        let peer = IRelayPairing.host(of: connection)
        connection.receive(minimumIncompleteLength: Self.preambleLength,
                           maximumLength: Self.preambleLength) { [weak self] data, _, _, _ in
            guard let self, let data, data.count == Self.preambleLength,
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("IRELAY "), text.hasSuffix("\n"),
                  IRelayPairing.authorize(String(text.dropFirst(7).dropLast()), from: peer) else {
                // Tells iRelay the code was refused, so it stops reconnecting
                // with it (each refusal counts toward the one-minute lockout)
                // and asks for the code shown in Settings.
                connection.send(content: Data("IRELAY-DENIED\n".utf8), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            self.addToPool(connection)
        }
    }

    private func addToPool(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.pool.removeAll { $0 === connection }
            default: break
            }
        }
        if !waiting.isEmpty {
            let (local, timeout) = waiting.removeFirst()
            timeout.cancel()
            join(local, connection)
        } else {
            pool.append(connection)
        }
    }

    private func addLocal(_ connection: NWConnection) {
        connection.start(queue: queue)
        if !pool.isEmpty {
            join(connection, pool.removeFirst())
            return
        }
        // No PC connection free yet: iRelay opens a new one as soon as one is used.
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.waiting.removeAll { $0.0 === connection }
            connection.cancel()
        }
        waiting.append((connection, timeout))
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func join(_ a: NWConnection, _ b: NWConnection) {
        a.stateUpdateHandler = { [weak b] state in
            if case .failed = state { b?.cancel() } else if case .cancelled = state { b?.cancel() }
        }
        b.stateUpdateHandler = { [weak a] state in
            if case .failed = state { a?.cancel() } else if case .cancelled = state { a?.cancel() }
        }
        copy(from: a, to: b)
        copy(from: b, to: a)
    }

    private func copy(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { source.cancel(); destination.cancel(); return }
                    if complete || error != nil {
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    } else {
                        self?.copy(from: source, to: destination)
                    }
                })
            } else if complete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    destination.cancel()
                })
                source.cancel()
            } else {
                self?.copy(from: source, to: destination)
            }
        }
    }
}
