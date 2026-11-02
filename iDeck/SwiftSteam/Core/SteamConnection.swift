// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Adapted for
// the owned library and downloads (docs/STEAM_LIBRARY.md).
// Connection recovery adapted from kuscholar/iDeck; see docs/STEAM_LIBRARY.md.

import Foundation

// MARK: - WebSocket Delegate

/// Logs WebSocket lifecycle events: protocol negotiation, server-initiated close.
/// URLSession calls these on its internal delegate queue.
private final class SteamWebSocketDelegate: NSObject, URLSessionWebSocketDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // This is the ground truth — what protocol the server actually agreed to.
        // If nil, the server did not echo "steamdataport" in its 101 response.
        SteamLog.trace("WS handshake complete — server protocol: \(`protocol` ?? "(none, server did not echo)")")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        SteamLog.trace("WS server closed — code: \(closeCode.rawValue) reason: \"\(reasonStr)\"")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            SteamLog.trace("WS task completed with error: \(SteamCMTransportPolicy.sanitized(error))")
        }
    }
}

// MARK: - SteamConnection

/// WebSocket transport to a Steam CM server (wss://).
/// TLS handles all encryption — no ChannelEncrypt handshake required.
/// Each binary WebSocket frame is exactly one complete Steam protocol message.
actor SteamConnection {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let wsDelegate = SteamWebSocketDelegate()
    private let serverList = CMServerList.shared
    private var currentEndpoint: String?
    private var activeConnect: UUID?
    private var messageHandler: ((Data) -> Void)?
    private var disconnectHandler: ((Error?) -> Void)?

    var isConnected: Bool {
        webSocketTask?.state == .running
    }

    // MARK: - Connect

    /// iDeck: how many CM servers are dialled at once.
    private static let raceWidth = 3

    /// iDeck: dials the best few servers at once (lowest measured ping first)
    /// and keeps the first whose WebSocket answers a ping, which is the one
    /// with the lowest ping right now; the others are closed. A failed round
    /// tries the next servers.
    func connect() async throws {
        disconnect()
        let generation = UUID()
        activeConnect = generation
        var tried = Set<String>()
        var lastFailure: Error?
        for round in 1...3 {
            try Task.checkCancellation()
            guard activeConnect == generation else { throw CancellationError() }
            let candidates: [CMServerList.CMServer]
            do { candidates = try await serverList.candidates(Self.raceWidth, excluding: tried) }
            catch { throw lastFailure ?? error }
            for server in candidates { tried.insert(server.endpoint) }
            SteamLog.trace("Connecting to CM (round \(round)): " + candidates.map(\.endpoint).joined(separator: ", "))
            let winner = await Self.race(candidates, delegate: wsDelegate)
            guard activeConnect == generation else {
                winner.socket?.task.cancel(with: .goingAway, reason: nil)
                winner.socket?.session.invalidateAndCancel()
                throw CancellationError()
            }
            for endpoint in winner.failed { await serverList.markFailed(endpoint: endpoint) }
            if let socket = winner.socket {
                urlSession = socket.session
                webSocketTask = socket.task
                currentEndpoint = socket.server.endpoint
                await serverList.markSuccess(endpoint: socket.server.endpoint)
                await serverList.recordLatency(endpoint: socket.server.endpoint, milliseconds: socket.milliseconds)
                scheduleReceive(socket.task)
                SteamLog.trace(String(format: "WebSocket connected to %@ in %.0f ms", socket.server.endpoint, socket.milliseconds))
                return
            }
            lastFailure = winner.error.map { SteamCMTransportPolicy.sanitized($0) } ?? SteamError.connectionTimeout
            SteamLog.event("[steam-cm-transport] round=\(round) failed=\(winner.failed.count)")
        }
        throw lastFailure ?? SteamError.noServersAvailable
    }

    private struct OpenSocket: @unchecked Sendable {
        let server: CMServerList.CMServer
        let session: URLSession
        let task: URLSessionWebSocketTask
        let milliseconds: Double
    }

    private struct RaceResult: @unchecked Sendable {
        var socket: OpenSocket?
        var failed: [String] = []
        var error: Error?
    }

    /// iDeck: every candidate at once; the first socket whose ping is answered wins.
    private static func race(_ servers: [CMServerList.CMServer], delegate: SteamWebSocketDelegate) async -> RaceResult {
        await withTaskGroup(of: (CMServerList.CMServer, OpenSocket?, Error?).self) { group in
            for server in servers {
                group.addTask {
                    let started = Date()
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 20
                    config.waitsForConnectivity = false
                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    let task = session.webSocketTask(with: server.url, protocols: ["steamdataport"])
                    task.resume()
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { ping in
                            ping.addTask {
                                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                                    task.sendPing { error in
                                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                                    }
                                }
                            }
                            ping.addTask {
                                try await Task.sleep(nanoseconds: 6_000_000_000)
                                throw SteamError.connectionTimeout
                            }
                            try await ping.next()
                            ping.cancelAll()
                        }
                        try Task.checkCancellation()
                        return (server, OpenSocket(server: server, session: session, task: task,
                                                   milliseconds: Date().timeIntervalSince(started) * 1000), nil)
                    } catch {
                        task.cancel(with: .goingAway, reason: nil)
                        session.invalidateAndCancel()
                        return (server, nil, error)
                    }
                }
            }
            var result = RaceResult()
            for await (server, socket, error) in group {
                if let socket {
                    if result.socket == nil {
                        result.socket = socket
                        group.cancelAll()
                    } else {
                        socket.task.cancel(with: .goingAway, reason: nil)
                        socket.session.invalidateAndCancel()
                    }
                } else if result.socket == nil, !(error is CancellationError) {
                    result.failed.append(server.endpoint)
                    result.error = error ?? result.error
                }
            }
            return result
        }
    }

    /// Madeira's one-server-at-a-time connect, kept for reference.
    private func connectSequentially() async throws {
        disconnect()
        let generation = UUID()
        activeConnect = generation
        var tried = Set<String>()
        var lastFailure: Error?
        for attempt in 1...3 {
            try Task.checkCancellation()
            guard activeConnect == generation else { throw CancellationError() }
            let server: CMServerList.CMServer
            do { server = try await serverList.getServer(excluding: tried) }
            catch {
                try Task.checkCancellation()
                guard activeConnect == generation else { throw CancellationError() }
                throw lastFailure ?? error
            }
            try Task.checkCancellation()
            guard activeConnect == generation else { throw CancellationError() }
            tried.insert(server.endpoint)
            do {
                try await connect(to: server)
                try Task.checkCancellation()
                guard activeConnect == generation else { throw CancellationError() }
                await serverList.markSuccess(endpoint: server.endpoint)
                try Task.checkCancellation()
                guard activeConnect == generation else { throw CancellationError() }
                guard let task = webSocketTask else { throw CancellationError() }
                scheduleReceive(task)
                SteamLog.trace("WebSocket connected — ready for protocol messages")
                return
            } catch {
                guard activeConnect == generation else { throw CancellationError() }
                clearTransport()
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled && (error as NSError).domain == NSURLErrorDomain {
                    throw CancellationError()
                }
                await serverList.markFailed(endpoint: server.endpoint)
                guard activeConnect == generation else { throw CancellationError() }
                let failure = SteamCMTransportPolicy.sanitized(error)
                SteamLog.event("[steam-cm-transport] attempt=\(attempt) reason=\(failure)")
                lastFailure = failure
                guard attempt < 3, SteamCMTransportPolicy.canTryAnotherServer(error) else { throw failure }
            }
        }
        throw lastFailure ?? SteamError.noServersAvailable
    }

    private func connect(to server: CMServerList.CMServer) async throws {
        currentEndpoint = server.endpoint
        SteamLog.trace("Connecting to CM: \(server.url)")

        // Build a custom URLSession with our delegate so we can observe the WS handshake.
        // The delegate tells us what protocol the server actually negotiated.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // Delegate queue nil → URLSession creates an internal serial queue (correct for our actor model)
        let session = URLSession(configuration: config, delegate: wsDelegate, delegateQueue: nil)
        urlSession = session

        // IMPORTANT: Sec-WebSocket-Protocol is a CONTROLLED HEADER in URLSessionWebSocketTask.
        // Setting it via request.setValue is silently ignored by URLSession.
        // The only supported way is the `protocols` parameter below.
        // Without "steamdataport", Steam CM servers accept the WebSocket but do not
        // initialize a Steam session handler, so they silently ignore all messages.
        let task = session.webSocketTask(with: server.url, protocols: ["steamdataport"])
        webSocketTask = task
        task.resume()

        // Verify the connection completed (WebSocket handshake + ping round-trip)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Receive

    /// Continuously receive WebSocket binary frames.
    /// Each frame is one complete Steam protocol message — no TCP length/magic framing.
    nonisolated private func scheduleReceive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { await self?.received(result, from: task) }
        }
    }

    private func received(_ result: Result<URLSessionWebSocketTask.Message, Error>, from task: URLSessionWebSocketTask) {
        guard webSocketTask === task else { return }
        switch result {
        case .success(let message):
            switch message {
            case .data(let data): messageHandler?(data)
            case .string(let text): SteamLog.trace("unexpected text frame (\(text.utf8.count) bytes)")
            @unknown default: break
            }
            scheduleReceive(task)
        case .failure(let error):
            // POSIX 57 (socket not connected) is a normal disconnect.
            let failure = error as NSError
            let isNormalClose = failure.domain == NSPOSIXErrorDomain && failure.code == 57
            handleDisconnect(task: task, error: isNormalClose ? nil : SteamCMTransportPolicy.sanitized(error))
        }
    }

    // MARK: - Send

    /// Send raw bytes as a binary WebSocket frame.
    /// Wire format: [4B masked EMsg][4B headerLen][protobuf header][body] — no TCP framing wrapper.
    func send(_ data: Data) async throws {
        guard let task = webSocketTask, task.state == .running else {
            throw SteamError.disconnected
        }
        try await task.send(.data(data))
    }

    func sendMessage(eMsg: EMsg, header: CMsgProtoBufHeader, body: Data) async throws {
        let encoded = SteamMessageCodec.encode(eMsg: eMsg, header: header, body: body)
        try await send(encoded)
    }

    /// WebSocket-level ping (transport keepalive).
    /// Steam protocol heartbeat is handled by SteamSession at the message level.
    func sendPing() async {
        webSocketTask?.sendPing { _ in }
    }

    // MARK: - Handlers

    func setMessageHandler(_ handler: @escaping (Data) -> Void) {
        self.messageHandler = handler
    }

    func setDisconnectHandler(_ handler: @escaping (Error?) -> Void) {
        self.disconnectHandler = handler
    }

    private func handleDisconnect(task: URLSessionWebSocketTask, error: Error?) {
        // Only fire disconnect once per connection — clear webSocketTask to prevent repeat
        guard webSocketTask === task else { return }
        let endpoint = currentEndpoint
        clearTransport()
        currentEndpoint = endpoint // reconnect() must still mark the disconnected CM as failed
        if let error {
            SteamLog.trace("Connection lost: \(error.localizedDescription)")
        } else {
            SteamLog.trace("Connection closed cleanly")
        }
        disconnectHandler?(error)
    }

    // MARK: - Disconnect

    private func clearTransport() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        currentEndpoint = nil
    }

    func disconnect() {
        activeConnect = nil
        clearTransport()
        SteamLog.trace("Disconnected")
    }

    func reconnect() async throws {
        if let endpoint = currentEndpoint {
            await serverList.markFailed(endpoint: endpoint)
        }
        disconnect()
        try await connect()
    }
}
