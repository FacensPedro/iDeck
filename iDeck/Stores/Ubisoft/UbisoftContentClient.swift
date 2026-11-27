// UbisoftContentClient.swift
// Split from UbisoftDownloader.swift (iDeck 3.0 architecture).

import Foundation

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
