import Foundation
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
    static let defaultPort = 27090

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
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
        guard IRelaySetting.enabled, !IRelaySetting.host.isEmpty else { return nil }
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
        let (data, response) = try await Self.session.data(for: request("ping", timeout: 4))
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
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Section {
            Toggle(tr("Download through iRelay"), isOn: $enabled)
            TextField(tr("PC address (e.g. 192.168.0.10)"), text: $host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(tr("Pairing code"), text: $code)
                .keyboardType(.numberPad)
            Button(testing ? tr("Connecting…") : tr("Test connection")) { test() }
                .disabled(testing || host.trimmingCharacters(in: .whitespaces).isEmpty)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("iRelay")
        } footer: {
            Text(tr("iRelay runs on a Windows PC on this network. While iDeck installs a Steam game, the PC downloads it too and sends each piece to iDeck as soon as it arrives. Enter the address and pairing code shown in iRelay's window. If the PC stops answering, the download continues from Steam."))
        }
    }

    private func test() {
        guard let client = IRelayClient(host: host, code: code.trimmingCharacters(in: .whitespaces)) else {
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
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
