import Foundation
import Network
import SwiftUI

/// iRelay (github.com/FacensPedro/iRelay): a Windows program that downloads a
/// Steam game's chunks on a PC while iDeck installs it, and hands them to iDeck
/// over the local network as soon as each one arrives.
///
/// iDeck talks to it directly over HTTP (port 27090 by default):
/// - `GET /ping`: name and version; checks the pairing code.
/// - `POST /jobs`: the chunks iDeck still needs, per depot, in the order it will
///   ask for them, with the content servers and their authorization. iRelay
///   starts downloading all of them at the PC's speed.
/// - `GET /depot/<id>/chunk/<sha>`: one chunk exactly as a content server sends
///   it (still encrypted and compressed). iRelay answers from its cache, waits
///   for a chunk being downloaded or fetches it at once. iDeck checks and
///   decrypts it as it does a content server's answer.
///
/// Every request carries the pairing code shown in iRelay's window
/// (`X-iRelay-Code`). Any failure falls back to Steam's content servers.
enum IRelaySetting {
    static let enabledKey = "ideck.irelay.enabled"
    static let hostKey = "ideck.irelay.host"
    static let codeKey = "ideck.irelay.code"
    static let cableKey = "ideck.irelay.cable"
    static let defaultPort = 27090

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// USB cable (default) or the local network.
    static var cable: Bool { UserDefaults.standard.object(forKey: cableKey) as? Bool ?? true }
    static var host: String {
        (UserDefaults.standard.string(forKey: hostKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var code: String {
        (UserDefaults.standard.string(forKey: codeKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "192.168.0.10", "192.168.0.10:27090" or "http://pc.local:27090".
    static func baseURL(_ host: String) -> URL? {
        var text = host
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text), parts.host?.isEmpty == false else { return nil }
        if parts.port == nil { parts.port = defaultPort }
        parts.path = ""
        return parts.url
    }
}

enum IRelayError: LocalizedError {
    case badAddress, unauthorized, status(Int), offline

    var errorDescription: String? {
        switch self {
        case .badAddress: return "The iRelay address is not valid."
        case .unauthorized: return "iRelay refused the pairing code."
        case .status(let code): return "iRelay answered HTTP \(code)."
        case .offline: return "iRelay stopped answering; using Steam's servers."
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

    let base: URL
    private let code: String
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

    init?(host: String, code: String) {
        guard let base = IRelaySetting.baseURL(host) else { return nil }
        self.base = base
        self.code = code
    }

    /// The iRelay set in Settings › Steam, when it is on.
    static func configured() -> IRelayClient? {
        guard IRelaySetting.enabled else { return nil }
        if IRelaySetting.cable {
            IRelayUSBTunnel.shared.start()
            return IRelayClient(host: "127.0.0.1:\(IRelayUSBTunnel.localPort)", code: IRelaySetting.code)
        }
        guard !IRelaySetting.host.isEmpty else { return nil }
        return IRelayClient(host: IRelaySetting.host, code: IRelaySetting.code)
    }

    var usable: Bool { lock.withLock { failureCount < 5 } }
    var chunks: Int { lock.withLock { chunkCount } }
    var bytes: Int { lock.withLock { byteCount } }
    var failures: Int { lock.withLock { failureCount } }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 90) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(code, forHTTPHeaderField: "X-iRelay-Code")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw IRelayError.unauthorized }
        guard (200...299).contains(status) else { throw IRelayError.status(status) }
    }

    func ping() async throws -> Info {
        let (data, response) = try await Self.session.data(for: request("ping", timeout: 10))
        try Self.check(response)
        let info = try JSONDecoder().decode(Info.self, from: data)
        lock.withLock { name = info.machine.map { "iRelay (\($0))" } ?? info.name }
        return info
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

    func recordSuccess(bytes: Int) {
        lock.withLock { chunkCount += 1; byteCount += bytes; failureCount = 0 }
    }

    /// True when this failure turned iRelay off for the install.
    @discardableResult func recordFailure() -> Bool {
        lock.withLock { failureCount += 1; return failureCount == 5 }
    }
}


/// Settings › Steam › iRelay.
struct IRelaySettingsSection: View {
    @AppStorage(IRelaySetting.enabledKey) private var enabled = false
    @AppStorage(IRelaySetting.hostKey) private var host = ""
    @AppStorage(IRelaySetting.codeKey) private var code = ""
    @AppStorage(IRelaySetting.cableKey) private var cable = true
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Section {
            Toggle(tr("Download through iRelay"), isOn: $enabled)
            Picker(tr("Connection"), selection: $cable) {
                Text(tr("USB cable")).tag(true)
                Text(tr("Wi-Fi")).tag(false)
            }
            if !cable {
                TextField(tr("PC address (e.g. 192.168.0.10)"), text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            TextField(tr("Pairing code"), text: $code)
                .keyboardType(.numberPad)
            Button(testing ? tr("Connecting…") : tr("Test connection")) { test() }
                .disabled(testing || (!cable && host.trimmingCharacters(in: .whitespaces).isEmpty))
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("iRelay")
        } footer: {
            Text(tr("iRelay runs on a Windows PC. While iDeck installs a Steam game, the PC downloads it too and sends each piece to iDeck as soon as it arrives. USB cable: connect the iPad to the PC, tap Trust on the iPad, and keep the Apple Devices app (or iTunes) installed on the PC. Enter the pairing code shown in iRelay's window. If the PC stops answering, the download continues from Steam."))
                .onAppear { if enabled && cable { IRelayUSBTunnel.shared.start() } }
        }
    }

    private func test() {
        if cable { IRelayUSBTunnel.shared.start() }
        let target = cable ? "127.0.0.1:\(IRelayUSBTunnel.localPort)" : host
        guard let client = IRelayClient(host: target, code: code.trimmingCharacters(in: .whitespaces)) else {
            status = IRelayError.badAddress.localizedDescription
            return
        }
        testing = true
        status = nil
        Task {
            do {
                let info = try await client.ping()
                status = tr("Connected to %@ (version %d).", info.machine ?? info.name, info.version)
            } catch {
                status = cable && !IRelayUSBTunnel.shared.pcConnected
                    ? tr("iRelay is not connected over the cable. Check the cable, tap Trust on the iPad and open iRelay on the PC.")
                    : error.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - USB cable

/// iRelay over a USB cable. iOS gives apps no USB networking of their own, but
/// a Windows PC with Apple's device service (the Apple Devices app or iTunes)
/// can open TCP connections to a port on a trusted, cabled iPad through
/// usbmux. So the direction is reversed:
///
/// - iRelay keeps a few connections open to this device's port 27091 over the
///   cable (`pcPort`); they wait here in a pool.
/// - iDeck's own requests go to 127.0.0.1:27092 (`localPort`); each accepted
///   connection is joined to one waiting cable connection and bytes are copied
///   both ways. iRelay joins its end to its HTTP server, so the same requests
///   (`IRelayClient`) work over the cable unchanged.
final class IRelayUSBTunnel: @unchecked Sendable {
    static let shared = IRelayUSBTunnel()
    static let pcPort: UInt16 = 27091
    static let localPort: UInt16 = 27092

    private let queue = DispatchQueue(label: "ideck.irelay.usb")
    private var pcListener: NWListener?
    private var localListener: NWListener?
    private var pool: [NWConnection] = []
    private var waiting: [(NWConnection, DispatchWorkItem)] = []

    /// Whether iRelay has connections waiting over the cable.
    var pcConnected: Bool { queue.sync { !pool.isEmpty } }

    /// Starts both listeners once; safe to call again.
    func start() {
        queue.sync {
            guard pcListener == nil else { return }
            pcListener = makeListener(port: Self.pcPort) { [weak self] connection in self?.addPC(connection) }
            localListener = makeListener(port: Self.localPort) { [weak self] connection in self?.addLocal(connection) }
        }
    }

    private func makeListener(port: UInt16, accept: @escaping (NWConnection) -> Void) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // usbmux delivers the PC's connections on the loopback interface.
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: port) else {
            AppLog.record("[irelay-usb] could not listen on port \(port)")
            return nil
        }
        listener.newConnectionHandler = accept
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                AppLog.record("[irelay-usb] listener \(port) failed: \(error)")
                self?.queue.async { self?.restart() }
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func restart() {
        pcListener?.cancel(); localListener?.cancel()
        pcListener = nil; localListener = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.pcListener = self.makeListener(port: Self.pcPort) { [weak self] c in self?.addPC(c) }
            self.localListener = self.makeListener(port: Self.localPort) { [weak self] c in self?.addLocal(c) }
        }
    }

    private func addPC(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.pool.removeAll { $0 === connection }
            default: break
            }
        }
        connection.start(queue: queue)
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
        // No cable connection free yet: iRelay opens a new one as soon as one is used.
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
