import Foundation
import Network
import SwiftUI
import UIKit

/// iRelay (github.com/FacensPedro/iRelay): a Windows program connected to this
/// iPad by USB cable. It works two ways:
///
/// 1. Games installed on the PC (Steam, GOG, Epic) are copied into iDeck's own
///    folders (`IRelayDeviceService`, port 27093): iRelay lists iDeck's
///    libraries, compares files and sends what is missing.
/// 2. While iDeck itself downloads a Steam game, iRelay downloads the same
///    chunks on the PC and hands each one over as it arrives (`IRelayClient`,
///    through `IRelayUSBTunnel`):
///    - `GET /ping`
///    - `POST /jobs`: the chunks iDeck still needs, per depot, in order, with
///      the content servers and their authorization.
///    - `GET /depot/<id>/chunk/<sha>`: one chunk as a content server sends it,
///      checked and decrypted here like a content server's answer.
///
/// The cable is the only connection: usbmux reaches only a PC this iPad trusts.
enum IRelaySetting {
    static let enabledKey = "ideck.irelay.enabled"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

enum IRelayError: LocalizedError {
    case status(Int), notConnected

    var errorDescription: String? {
        switch self {
        case .status(let code): return "iRelay answered HTTP \(code)."
        case .notConnected: return "iRelay is not connected over the USB cable."
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

    let base = URL(string: "http://127.0.0.1:\(IRelayUSBTunnel.localPort)")!
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
        guard IRelaySetting.enabled else { return nil }
        IRelayUSBTunnel.shared.start()
        return IRelayClient()
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
            if !IRelayUSBTunnel.shared.pcConnected { throw IRelayError.notConnected }
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
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Section {
            Toggle(tr("Use iRelay (USB cable)"), isOn: $enabled)
                .onChange(of: enabled) { _, on in if on { IRelayRuntime.start() } }
            Button(testing ? tr("Connecting…") : tr("Test connection")) { test() }
                .disabled(testing || !enabled)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("iRelay")
        } footer: {
            Text(tr("iRelay runs on a Windows PC connected to this iPad by USB cable. It installs your Steam, GOG and Epic games on the PC and copies them into iDeck, and speeds up downloads started here. Connect the cable, tap Trust on the iPad, keep the Apple Devices app (or iTunes) and iRelay on the PC, and keep iDeck open during transfers."))
        }
        .onAppear { if enabled { IRelayRuntime.start() } }
    }

    private func test() {
        IRelayRuntime.start()
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
    static func start() {
        guard IRelaySetting.enabled else { return }
        IRelayUSBTunnel.shared.start()
        IRelayDeviceService.shared.start()
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
