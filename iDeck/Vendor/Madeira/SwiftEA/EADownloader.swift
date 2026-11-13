// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Compression
import Foundation

// Installing an EA build (docs/EA.md, "A download"): EA's CDN serves each build
// as one zip archive, often tens of gigabytes. Madeira reads the archive's table
// of contents from its tail with range requests, then fetches each file's bytes
// with its own range request and inflates them straight into the game's folder,
// checking the CRC-32 the archive records. Nothing of the archive is stored
// whole. The approach follows the EA app's own installer and Maxima (GPL-3.0);
// no Maxima code is included. Self-contained: nothing here depends on another
// store's code.

/// Progress of one EA download, published to the library model.
struct EADownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, verifying, downloading, finishing }
    var phase: Phase = .preparing
    /// Downloading: compressed bytes to fetch and fetched. Verifying: file bytes to check and checked.
    var totalBytes: UInt64 = 0
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    /// Preparing: what is being fetched from EA ("Reading the build's file list").
    var step: String?
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

enum EADownloadError: LocalizedError {
    case diskSpace(needed: Int64)
    case file(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .diskSpace(let needed):
            return "Not enough free space on this device: this download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) more. Free some space, then try again."
        case .file(let reason): return "A game file could not be downloaded from EA (\(reason)). Try again to continue."
        case .unsafePath(let name): return "EA's build names a file outside the game's folder (\(name))."
        }
    }
}

/// A build's table of contents and where it lives.
struct EABuildArchive: Sendable {
    var url: URL
    var fileSize: Int64
    var entries: [EAZipEntry]
    var files: [EAZipEntry] { entries.filter { !$0.isDirectory } }
    var compressedBytes: Int64 { files.reduce(0) { $0 + $1.compressedSize } }
    var installBytes: Int64 { files.reduce(0) { $0 + $1.uncompressedSize } }
}

/// iDeck: a counting gate for range requests. Waiters are served in order.
actor EARangeGate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { free = Swift.max(1, limit) }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the slot to the next waiter, or frees it.
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Reading from EA's CDN by byte range.
final class EARangeClient: @unchecked Sendable {
    private let http: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        config.httpMaximumConnectionsPerHost = DownloadSpeed.eaConnections
        config.httpAdditionalHeaders = ["User-Agent": EAAPI.userAgent]
        http = URLSession(configuration: config)
    }

    /// The archive's size, from a HEAD request.
    func size(of url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EADownloadError.file("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for the build's size")
        }
        guard let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), length > 0 else {
            throw EADownloadError.file("no size for the build")
        }
        return length
    }

    /// iDeck: how many whole-range requests are in flight. Eight files of sixteen
    /// ranges each used to hand URLSession up to 128 requests for its 40 connections;
    /// the ones it queued kept their 60 s timeout running while they waited for a
    /// connection, timed out and were fetched again, so a download stopped for a
    /// while and then went on. A request now waits here, with no clock running, and
    /// reaches URLSession only when a connection is free for it.
    private let gate = EARangeGate(DownloadSpeed.eaRangeRequests)

    /// Bytes `range` of the archive, whole.
    func bytes(_ url: URL, range: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        // A connection that stops sending is given up after 30 s instead of 60.
        request.timeoutInterval = 30
        await gate.acquire()
        let result: (Data, URLResponse)
        do {
            try Task.checkCancellation()
            result = try await http.data(for: request, delegate: LowPriority.shared)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw EADownloadError.file("HTTP \((result.1 as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return result.0
    }

    /// Bytes `range` of the archive as they arrive, with back-pressure: the
    /// connection is suspended while more than `EARangeStream.highWater` bytes
    /// wait for the consumer. Without it the network outran the inflater and
    /// the waiting chunks filled memory (5.8 GB, then iOS ended iDeck), and a
    /// pause had to wait for that backlog.
    func stream(_ url: URL, range: Range<Int64>) -> EARangeStream {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let flow = EARangeStream.Flow()
        let http = self.http
        let inner = AsyncThrowingStream<Data, Error> { continuation in
            let delegate = StreamDelegate(continuation: continuation, flow: flow)
            let task = http.dataTask(with: request)
            // Bulk data: covers and the rest of the app go first.
            task.priority = URLSessionTask.lowPriority
            task.delegate = delegate
            flow.task = task
            continuation.onTermination = { _ in flow.finish(); task.cancel() }
            task.resume()
        }
        return EARangeStream(inner: inner, flow: flow)
    }

    /// Bulk ranges yield to covers and the rest of the app.
    private final class LowPriority: NSObject, URLSessionTaskDelegate {
        static let shared = LowPriority()
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            task.priority = URLSessionTask.lowPriority
        }
    }

    private final class StreamDelegate: NSObject, URLSessionDataDelegate {
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        let flow: EARangeStream.Flow
        init(continuation: AsyncThrowingStream<Data, Error>.Continuation, flow: EARangeStream.Flow) {
            self.continuation = continuation
            self.flow = flow
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
                continuation.finish(throwing: EADownloadError.file("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
                completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            flow.received(data.count)
            continuation.yield(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    /// EA's CDNs that serve the same build paths. EA's download address names one;
    /// which is fastest depends on the player's network (their IP's route to each).
    static let mirrorHosts = ["origin-a.akamaihd.net", "lvlt.cdn.ea.com", "download.dm.origin.com"]

    /// Measures the first 1 MB of the archive from EA's address and each mirror at once,
    /// keeps only mirrors that serve the same file (206, same total size), and returns
    /// the fastest. Any failure keeps EA's own address.
    func fastestMirror(for url: URL, size: Int64) async -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url }
        var candidates = [url]
        for mirror in Self.mirrorHosts where mirror != host {
            components.host = mirror
            if let alternate = components.url { candidates.append(alternate) }
        }
        let probeBytes: Int64 = min(1 << 20, size)
        guard probeBytes > 0 else { return url }
        let timings = await withTaskGroup(of: (URL, TimeInterval?).self) { group -> [(URL, TimeInterval)] in
            for candidate in candidates {
                group.addTask {
                    var request = URLRequest(url: candidate, timeoutInterval: 8)
                    request.setValue("bytes=0-\(probeBytes - 1)", forHTTPHeaderField: "Range")
                    let start = Date()
                    guard let (data, response) = try? await self.http.data(for: request),
                          let reply = response as? HTTPURLResponse, reply.statusCode == 206,
                          Int64(data.count) == probeBytes,
                          reply.value(forHTTPHeaderField: "Content-Range")?.hasSuffix("/\(size)") == true else {
                        return (candidate, nil)
                    }
                    return (candidate, Date().timeIntervalSince(start))
                }
            }
            var results: [(URL, TimeInterval)] = []
            for await (candidate, time) in group { if let time { results.append((candidate, time)) } }
            return results
        }
        guard let best = timings.min(by: { $0.1 < $1.1 }) else { return url }
        let summary = timings.map { "\($0.0.host ?? "?")=\(Int($0.1 * 1000))ms" }.joined(separator: " ")
        EALog.event("[ea-download] cdn chosen=\(best.0.host ?? "?") \(summary)")
        return best.0
    }

    /// The archive's table of contents.
    func archive(_ url: URL) async throws -> EABuildArchive {
        let size = try await self.size(of: url)
        let tailLength = min(size, 256 * 1024)
        let tail = try await bytes(url, range: (size - tailLength)..<size)
        let location: EAZipDirectory.Location
        switch try EAZipDirectory.locate(tail: tail, fileSize: size) {
        case .found(let found): location = found
        case .needsRecord(let offset):
            guard offset >= 0, offset + 56 <= size else { throw EAZipError.bad("zip64 record offset") }
            location = try EAZipDirectory.location(zip64Record: try await bytes(url, range: offset..<offset + 56))
        }
        guard location.offset >= 0, location.size > 0, location.size <= 256 << 20, location.offset + location.size <= size else {
            throw EAZipError.bad("central directory bounds")
        }
        let directory = try await bytes(url, range: location.offset..<location.offset + location.size)
        let entries = try EAZipDirectory.entries(directory)
        guard !entries.isEmpty else { throw EAZipError.noDirectory }
        for entry in entries where EAZipDirectory.safeComponents(entry.name) == nil && !entry.isDirectory {
            throw EADownloadError.unsafePath(entry.name)
        }
        return EABuildArchive(url: url, fileSize: size, entries: entries)
    }
}

/// A byte-range stream that tells the connection what the consumer has taken,
/// so the connection pauses while too much waits in memory.
struct EARangeStream: AsyncSequence {
    typealias Element = Data
    static let highWater = 8 << 20
    static let lowWater = 2 << 20

    /// Past this the delivering thread itself waits: suspend() alone did not stop
    /// data already in flight (HTTP/2 windows), and memory still reached 5.9 GB.
    static let hardLimit = 24 << 20

    final class Flow: @unchecked Sendable {
        private let condition = NSCondition()
        private var waiting = 0
        private var suspended = false
        private var finished = false
        weak var task: URLSessionDataTask?

        func received(_ count: Int) {
            condition.lock(); defer { condition.unlock() }
            waiting += count
            if !suspended && waiting > EARangeStream.highWater {
                suspended = true
                task?.suspend()
            }
            // True back-pressure: hold URLSession's delegate thread until the consumer
            // has taken most of it (or the stream ended). iDeck: at most 5 s, not 30:
            // that thread delivers every other transfer of the session too, so a long
            // hold here stopped the whole download.
            let deadline = Date().addingTimeInterval(5)
            while waiting > EARangeStream.hardLimit && !finished {
                if !condition.wait(until: deadline) { break }
            }
        }

        func consumed(_ count: Int) {
            condition.lock(); defer { condition.unlock() }
            waiting = Swift.max(0, waiting - count)
            if suspended && waiting < EARangeStream.lowWater {
                suspended = false
                task?.resume()
            }
            condition.broadcast()
        }

        /// The stream ended or was cancelled: release a waiting delivery.
        func finish() {
            condition.lock(); finished = true; condition.broadcast(); condition.unlock()
        }
    }

    let inner: AsyncThrowingStream<Data, Error>
    let flow: Flow

    struct AsyncIterator: AsyncIteratorProtocol {
        var inner: AsyncThrowingStream<Data, Error>.AsyncIterator
        let flow: Flow
        mutating func next() async throws -> Data? {
            // A pause stops at the next chunk, not after the backlog.
            try Task.checkCancellation()
            guard let chunk = try await inner.next() else { return nil }
            flow.consumed(chunk.count)
            return chunk
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(inner: inner.makeAsyncIterator(), flow: flow) }
}

/// Raw DEFLATE (or a stored entry) to a file, with the CRC-32 and size of what came out.
/// The decoder is EAInflate (EAFormats.swift), host-tested against zlib.
private final class EAInflater {
    /// The decoder, nil for a stored (uncompressed) entry.
    private var inflate: EAInflate?
    /// Apple's DEFLATE decoder (Compression), several times faster than EAInflate.
    /// Its result is checked like any other (size and CRC-32); a file it gets wrong
    /// is decoded again with EAInflate (`native: false`).
    private var native: EANativeInflate?
    private let handle: FileHandle
    private(set) var crc = EACRC32()
    private(set) var written: Int64 = 0
    /// The DEFLATE stream reached its final block's end (always true for a stored entry).
    var ended: Bool { native?.finished ?? inflate?.finished ?? true }

    init(handle: FileHandle, inflate: Bool, native useNative: Bool = true) {
        self.handle = handle
        if inflate, useNative, let decoder = EANativeInflate() { native = decoder }
        else { self.inflate = inflate ? EAInflate() : nil }
    }

    func write(_ data: Data, last: Bool) throws {
        let out: Data
        if native != nil {
            do { out = try native!.feed(data, last: last) } catch { throw EADownloadError.file("inflate") }
        } else if inflate != nil {
            do { out = Data(try inflate!.feed(data)) } catch { throw EADownloadError.file("inflate") }
        } else {
            out = data
        }
        if !out.isEmpty {
            // Each slab's bridged NSData is released at once, not when the task's
            // pool drains.
            try autoreleasepool { try handle.write(contentsOf: out) }
            crc.update(out); written += Int64(out.count)
        }
    }
}

/// Raw DEFLATE through compression_stream (COMPRESSION_ZLIB is raw DEFLATE). Every
/// call drains the decoder completely (it stops whenever its 1 MB output buffer
/// fills, which a decoder fed in pieces must loop on), and the last call finalizes.
private final class EANativeInflate {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    private(set) var finished = false

    init?() {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            buffer.deallocate(); return nil
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        buffer.deallocate()
    }

    func feed(_ data: Data, last: Bool) throws -> Data {
        var out = Data()
        guard !finished else { return out }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = data.count
            let flags = last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = 1 << 20
                let status = compression_stream_process(&stream, flags)
                let produced = (1 << 20) - stream.dst_size
                if produced > 0 { out.append(buffer, count: produced) }
                switch status {
                case COMPRESSION_STATUS_END:
                    finished = true
                    return
                case COMPRESSION_STATUS_OK:
                    // Done with this input only when it is all taken and the output
                    // buffer was not filled (a full buffer may hold more to give).
                    if stream.src_size == 0 && produced < (1 << 20) && !last { return }
                    if last && produced == 0 && stream.src_size == 0 { return }
                default:
                    throw EADownloadError.file("inflate")
                }
            }
        }
        return out
    }
}

/// Bytes fetched per second over the last few seconds, published at most a few times a second.
final class EAMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: EADownloadProgress
    private var samples: [(Date, UInt64)] = []
    private var lastPublish = Date.distantPast
    private let publish: (EADownloadProgress) -> Void

    init(_ progress: EADownloadProgress, publish: @escaping (EADownloadProgress) -> Void) {
        self.progress = progress; self.publish = publish
    }

    func set(_ change: (inout EADownloadProgress) -> Void) {
        lock.lock(); change(&progress); let copy = progress; lock.unlock()
        publish(copy)
    }

    func add(_ bytes: UInt64) {
        lock.lock()
        progress.doneBytes += bytes
        let now = Date()
        samples.append((now, progress.doneBytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
            progress.bytesPerSecond = Double(progress.doneBytes - first.1) / now.timeIntervalSince(first.0)
        }
        let due = now.timeIntervalSince(lastPublish) > 0.3
        if due { lastPublish = now }
        let copy = progress
        lock.unlock()
        if due { publish(copy) }
    }

    /// Takes back the bytes of a failed attempt.
    func remove(_ bytes: UInt64) {
        guard bytes > 0 else { return }
        lock.lock()
        progress.doneBytes -= min(bytes, progress.doneBytes)
        samples.removeAll()
        let copy = progress
        lock.unlock()
        publish(copy)
    }

    func finish() { lock.lock(); let copy = progress; lock.unlock(); publish(copy) }
}

/// Finished files of a download in progress, so Resume skips them.
final class EAJournal {
    private let url: URL
    private var done: Set<String> = []
    private let lock = NSLock()
    private static func key(_ entry: EAZipEntry) -> String { String(entry.crc32, radix: 16) + "\t" + String(entry.uncompressedSize) + "\t" + entry.name }

    init(url: URL) {
        self.url = url
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            done = Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        }
    }

    func contains(_ entry: EAZipEntry) -> Bool { lock.lock(); defer { lock.unlock() }; return done.contains(Self.key(entry)) }

    func record(_ entry: EAZipEntry) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(entry)
        guard done.insert(key).inserted else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data((key + "\n").utf8)); try? handle.close()
        } else {
            try? Data((key + "\n").utf8).write(to: url)
        }
    }

    func finish() { try? FileManager.default.removeItem(at: url) }
}

final class EADownloader: @unchecked Sendable {
    private let client = EARangeClient()
    /// Files fetched at once. Each is one range request, streamed.
    private let parallel = DownloadSpeed.eaFiles

    func archive(_ url: URL) async throws -> EABuildArchive { try await client.archive(url) }

    /// The archive on the EA CDN that answers fastest from this device's network.
    func fastestMirror(_ archive: EABuildArchive) async -> EABuildArchive {
        var chosen = archive
        chosen.url = await client.fastestMirror(for: archive.url, size: archive.fileSize)
        return chosen
    }

    struct Result: Sendable {
        var filesWritten: Int
        var filesKept: Int
        var bytesFetched: UInt64
        var installBytes: Int64
    }

    /// Installs the build into `folder`. `previous` is the installed build's file list for
    /// an update (files whose CRC and size are unchanged stay; files the new build no
    /// longer has go), nil for a first install or a repair; `verifyAll` checks every
    /// present file's CRC (repair). Cancellation pauses: the journal keeps what finished.
    func install(archive: EABuildArchive, folder: URL, previous: [EAZipEntry]?, verifyAll: Bool, journal journalURL: URL,
                 progress publish: @escaping @Sendable (EADownloadProgress) -> Void) async throws -> Result {
        let meter = EAMeter(EADownloadProgress(phase: .preparing, step: "Checking the game's folder"), publish: publish)
        let journal = EAJournal(url: journalURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = archive.files
        let previousByName = Dictionary((previous ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // What is already right: journaled files, and an update's unchanged files.
        var toFetch: [EAZipEntry] = []
        var kept = 0
        var verifyBytes: Int64 = 0
        var toVerify: [EAZipEntry] = []
        for entry in files {
            guard let parts = EAZipDirectory.safeComponents(entry.name) else { throw EADownloadError.unsafePath(entry.name) }
            let url = Self.url(folder, parts)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if !verifyAll, journal.contains(entry), size == entry.uncompressedSize { kept += 1; continue }
            if !verifyAll, let old = previousByName[entry.name], old.crc32 == entry.crc32, old.uncompressedSize == entry.uncompressedSize,
               size == entry.uncompressedSize { kept += 1; continue }
            if verifyAll, size == entry.uncompressedSize { toVerify.append(entry); verifyBytes += entry.uncompressedSize; continue }
            toFetch.append(entry)
        }
        if !toVerify.isEmpty {
            meter.set { $0.phase = .verifying; $0.totalBytes = UInt64(verifyBytes); $0.doneBytes = 0; $0.step = nil }
            for entry in toVerify {
                try Task.checkCancellation()
                let url = Self.url(folder, EAZipDirectory.safeComponents(entry.name) ?? [])
                if try Self.matches(url, entry, progress: { meter.add(UInt64($0)) }) { kept += 1 } else { toFetch.append(entry) }
            }
        }

        // Free space: what has to be written, less what the files being replaced hold.
        let needed = toFetch.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        if let free = Self.freeSpace(at: folder), needed + 512 << 20 > free {
            throw EADownloadError.diskSpace(needed: needed + 512 << 20 - free)
        }
        for entry in archive.entries where entry.isDirectory {
            if let parts = EAZipDirectory.safeComponents(entry.name) {
                try? FileManager.default.createDirectory(at: Self.url(folder, parts), withIntermediateDirectories: true)
            }
        }

        meter.set { $0.phase = .downloading; $0.totalBytes = UInt64(toFetch.reduce(Int64(0)) { $0 + $1.compressedSize }); $0.doneBytes = 0; $0.step = nil }
        EALog.event("[ea-download] plan files=\(files.count) fetch=\(toFetch.count) kept=\(kept) bytes=\(needed)")
        var fetched: UInt64 = 0
        var written = 0
        // Largest first: the long transfers start early and the small files fill the gaps.
        // A file that fails all its attempts does not stop the others: the pass finishes,
        // the failed files get two more passes (one at a time), and only then does the
        // download fail, naming the first file that still would not come.
        var order = toFetch.sorted { $0.compressedSize > $1.compressedSize }
        for pass in 1...3 where !order.isEmpty {
            var failed: [(EAZipEntry, Error)] = []
            let width = pass == 1 ? parallel : 1
            try await withThrowingTaskGroup(of: (EAZipEntry, Swift.Result<UInt64, Error>).self) { group in
                var next = 0
                func add() {
                    guard next < order.count else { return }
                    let entry = order[next]; next += 1
                    group.addTask { [client] in
                        try Task.checkCancellation()
                        do {
                            let bytes = try await Self.fetch(entry, archive: archive, client: client, folder: folder, meter: meter)
                            journal.record(entry)
                            return (entry, .success(bytes))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            return (entry, .failure(error))
                        }
                    }
                }
                for _ in 0..<width { add() }
                while let (entry, result) = try await group.next() {
                    switch result {
                    case .success(let bytes): fetched += bytes; written += 1
                    case .failure(let error): failed.append((entry, error))
                    }
                    add()
                }
            }
            order = failed.map(\.0)
            if !failed.isEmpty {
                EALog.event("[ea-download] pass=\(pass) failed-files=\(failed.count) first=\((failed[0].1 as? EADownloadError)?.errorDescription?.prefix(60) ?? "\(type(of: failed[0].1))")")
                if pass == 3 { throw failed[0].1 }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        meter.set { $0.phase = .finishing }

        // An update: files the new build no longer has.
        if let previous {
            let names = Set(files.map(\.name))
            for old in previous where !names.contains(old.name) && !old.isDirectory {
                if let parts = EAZipDirectory.safeComponents(old.name) { try? FileManager.default.removeItem(at: Self.url(folder, parts)) }
            }
        }
        journal.finish()
        meter.finish()
        return Result(filesWritten: written, filesKept: kept, bytesFetched: fetched, installBytes: archive.installBytes)
    }

    static func url(_ folder: URL, _ parts: [String]) -> URL {
        parts.reduce(folder) { $0.appendingPathComponent($1) }
    }

    /// Whether the file on disk has the entry's size and CRC-32.
    static func matches(_ url: URL, _ entry: EAZipEntry, progress: (Int) -> Void = { _ in }) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var crc = EACRC32()
        var total: Int64 = 0
        while true {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            crc.update(chunk); total += Int64(chunk.count)
            progress(chunk.count)
        }
        return total == entry.uncompressedSize && crc.checksum == entry.crc32
    }

    /// One file: its local header and data in one range, inflated into place. Returns the
    /// compressed bytes fetched.
    private static func fetch(_ entry: EAZipEntry, archive: EABuildArchive, client: EARangeClient, folder: URL, meter: EAMeter) async throws -> UInt64 {
        guard let parts = EAZipDirectory.safeComponents(entry.name) else { throw EADownloadError.unsafePath(entry.name) }
        let destination = url(folder, parts)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if entry.uncompressedSize == 0 {
            try Data().write(to: destination, options: .atomic)
            return 0
        }
        guard entry.method == 0 || entry.method == 8 else { throw EADownloadError.file("compression method \(entry.method)") }
        if entry.compressedSize >= segmentedThreshold {
            return try await fetchSegmented(entry, archive: archive, client: client, destination: destination, meter: meter)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent + ".madeira-part")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw EADownloadError.file("create") }
        let handle = try FileHandle(forWritingTo: temporary)
        var closed = false
        defer { if !closed { try? handle.close(); try? FileManager.default.removeItem(at: temporary) } }

        var attempt = 0
        while true {
            attempt += 1
            // Bytes this attempt added to the progress; a failed attempt takes them back, so
            // retries do not push the count past the total (build 58: 39.2 MB of 32.4 MB).
            var counted: UInt64 = 0
            do {
                try handle.truncate(atOffset: 0)
                // Apple's decoder on the first attempt; a retry uses EAInflate.
                let inflater = EAInflater(handle: handle, inflate: entry.method == 8, native: attempt == 1)
                // The local header (30 bytes, its own name and extra field) then the data; the
                // expected header length comes from the central directory, with a little room.
                let nameLength = Int64(entry.name.utf8.count)
                let guess = 30 + nameLength + 64
                let start = entry.localHeaderOffset
                let end = min(archive.fileSize, start + guess + entry.compressedSize)
                var header = Data()
                var headerLength: Int?
                var headerDone = false
                var firstChunk = 0
                var remaining = entry.compressedSize
                var fetched: UInt64 = 0
                for try await chunk in client.stream(archive.url, range: start..<end) {
                    var data = Data(chunk)
                    if !headerDone {
                        // The header can arrive in pieces (a new connection's first record is
                        // often tiny): keep collecting until the whole header is here. Build 58
                        // took the piece after a short first chunk as data, and the file's
                        // checksum failed every time.
                        if firstChunk == 0 { firstChunk = data.count }
                        header.append(data)
                        guard header.count >= 30 else { continue }
                        if headerLength == nil {
                            guard let length = EAZipDirectory.localHeaderLength(header) else { throw EADownloadError.file("local header") }
                            headerLength = length
                        }
                        guard let length = headerLength, header.count >= length else { continue }
                        data = Data(header[length...])
                        header = Data()
                        headerDone = true
                    }
                    if Int64(data.count) > remaining { data = Data(data.prefix(Int(remaining))) }
                    remaining -= Int64(data.count)
                    fetched += UInt64(data.count)
                    meter.add(UInt64(data.count)); counted += UInt64(data.count)
                    try inflater.write(data, last: remaining == 0)
                    if remaining == 0 { break }
                }
                if remaining > 0, let headerLength {
                    // The header was longer than guessed: the rest of the data in a second range.
                    // When the header itself ran past the first range, no data was written yet
                    // and this fetches all of it from just after the header.
                    let dataStart = start + Int64(headerLength) + (entry.compressedSize - remaining)
                    for try await chunk in client.stream(archive.url, range: dataStart..<dataStart + remaining) {
                        var data = Data(chunk)
                        if Int64(data.count) > remaining { data = Data(data.prefix(Int(remaining))) }
                        remaining -= Int64(data.count)
                        fetched += UInt64(data.count)
                        meter.add(UInt64(data.count)); counted += UInt64(data.count)
                        try inflater.write(data, last: remaining == 0)
                        if remaining == 0 { break }
                    }
                }
                guard remaining == 0 else { throw EADownloadError.file("short read") }
                try inflater.write(Data(), last: true)
                guard inflater.written == entry.uncompressedSize, inflater.crc.checksum == entry.crc32 else {
                    EALog.event("[ea-download] checksum name=\(parts.last!) method=\(entry.method) size=\(inflater.written)/\(entry.uncompressedSize)"
                                + " crc=\(String(inflater.crc.checksum, radix: 16))/\(String(entry.crc32, radix: 16)) header=\(headerLength ?? -1)/\(guess)"
                                + " first-chunk=\(firstChunk) compressed=\(entry.compressedSize) ended=\(inflater.ended ? 1 : 0)")
                    throw EADownloadError.file("checksum " + parts.last!)
                }
                try handle.close(); closed = true
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                return fetched
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                meter.remove(counted)
                if Task.isCancelled { throw CancellationError() }
                guard attempt < 4 else { throw error }
                EALog.event("[ea-download] retry file attempt=\(attempt) reason=\((error as? EADownloadError)?.errorDescription?.prefix(60) ?? "\(type(of: error))")")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    // As iDeck's Steam downloads (DownloadSpeed.steamChunks): a large file is fetched
    // as many small ranges at once instead of one long stream, which on EA's CDN
    // was limited to a single connection's speed for files of several GB.
    static let segmentedThreshold: Int64 = 16 << 20
    // RAM: each range is held in memory until written; 2 MB ranges halve what the
    // concurrent requests keep (was 4 MB).
    static let segmentBytes: Int64 = 2 << 20
    static let segmentsAtOnce = DownloadSpeed.eaSegments

    /// One large file: its compressed bytes in `segmentBytes` ranges, `segmentsAtOnce`
    /// at a time, written in place into a side file, then inflated from disk with the
    /// same size and CRC-32 checks as the streamed path.
    private static func fetchSegmented(_ entry: EAZipEntry, archive: EABuildArchive, client: EARangeClient,
                                       destination: URL, meter: EAMeter) async throws -> UInt64 {
        let folder = destination.deletingLastPathComponent()
        let compressed = folder.appendingPathComponent("." + destination.lastPathComponent + ".madeira-gz")
        let temporary = folder.appendingPathComponent("." + destination.lastPathComponent + ".madeira-part")
        // iDeck: the ranges already written into the side file, so a paused download
        // of a large file continues instead of starting the file again. Both files
        // are removed when the file is finished or its data does not check out.
        let marks = folder.appendingPathComponent("." + destination.lastPathComponent + ".madeira-seg")
        func discardPartial() {
            try? FileManager.default.removeItem(at: compressed)
            try? FileManager.default.removeItem(at: marks)
        }

        // The local header's own length (its name and extra field can differ from the
        // central directory's), so the data starts where it really does.
        let start = entry.localHeaderOffset
        let guess = 30 + Int64(entry.name.utf8.count) + 512
        let header = try await client.bytes(archive.url, range: start..<min(archive.fileSize, start + guess))
        guard let headerLength = EAZipDirectory.localHeaderLength(header) else { throw EADownloadError.file("local header") }
        let dataStart = start + Int64(headerLength)
        let total = entry.compressedSize
        guard dataStart + total <= archive.fileSize else { throw EADownloadError.file("data bounds") }

        let ranges = stride(from: Int64(0), to: total, by: Int(segmentBytes)).map { $0..<min($0 + segmentBytes, total) }
        // "<compressed size> <segment size> <crc32>" then one finished range index per line.
        let signature = "\(total) \(segmentBytes) \(entry.crc32)"
        var finished = Set<Int>()
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? NSNumber)?.int64Value
        if existingSize == total, let text = try? String(contentsOf: marks, encoding: .utf8) {
            let lines = text.split(separator: "\n").map(String.init)
            if lines.first == signature {
                finished = Set(lines.dropFirst().compactMap { Int($0) }.filter { ranges.indices.contains($0) })
            }
        }
        if finished.isEmpty {
            discardPartial()
            guard FileManager.default.createFile(atPath: compressed.path, contents: nil) else { throw EADownloadError.file("create") }
            try (signature + "\n").write(to: marks, atomically: true, encoding: .utf8)
        } else {
            EALog.event("[ea-download] resuming name=\(destination.lastPathComponent) ranges=\(finished.count)/\(ranges.count)")
        }
        let output = try FileHandle(forWritingTo: compressed)
        if existingSize != total || finished.isEmpty { try output.truncate(atOffset: UInt64(total)) }
        let marker = try FileHandle(forWritingTo: marks)
        try marker.seekToEnd()
        let writeLock = NSLock()
        final class Added: @unchecked Sendable { var bytes: UInt64 = 0 }
        let added = Added()
        // Ranges kept from before the pause count as downloaded.
        let keptBytes = finished.reduce(UInt64(0)) { $0 + UInt64(ranges[$1].count) }
        added.bytes = keptBytes
        meter.add(keptBytes)
        let pending = ranges.indices.filter { !finished.contains($0) }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < pending.count else { return }
                    let index = pending[next]; next += 1
                    let range = ranges[index]
                    group.addTask {
                        var attempt = 0
                        while true {
                            attempt += 1
                            try Task.checkCancellation()
                            do {
                                let data = try await client.bytes(archive.url, range: (dataStart + range.lowerBound)..<(dataStart + range.upperBound))
                                guard Int64(data.count) == range.count else { throw EADownloadError.file("short range") }
                                try writeLock.withLock {
                                    try output.seek(toOffset: UInt64(range.lowerBound))
                                    try autoreleasepool { try output.write(contentsOf: data) }
                                    try marker.write(contentsOf: Data("\(index)\n".utf8))
                                }
                                writeLock.withLock { added.bytes += UInt64(data.count) }
                                meter.add(UInt64(data.count))
                                return
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                if Task.isCancelled { throw CancellationError() }
                                guard attempt < 4 else { throw error }
                                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                            }
                        }
                    }
                }
                for _ in 0..<segmentsAtOnce { add() }
                while try await group.next() != nil { add() }
            }
            try output.close()
            try? marker.close()
        } catch {
            try? output.close()
            try? marker.close()
            // A failed file takes back what it counted, as the streamed path does.
            // Its side file and finished ranges stay for the next attempt.
            meter.remove(writeLock.withLock { added.bytes })
            throw error
        }

        // Inflate from disk, 4 MB at a time: Apple's decoder first, EAInflate if
        // its result does not check out (no download again either way).
        var inflatedOK = false
        for useNative in [true, false] where !inflatedOK {
            try? FileManager.default.removeItem(at: temporary)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw EADownloadError.file("create") }
            let part = try FileHandle(forWritingTo: temporary)
            let input = try FileHandle(forReadingFrom: compressed)
            do {
                let inflater = EAInflater(handle: part, inflate: entry.method == 8, native: useNative)
                var remaining = total
                while remaining > 0 {
                    try Task.checkCancellation()
                    let slab = try autoreleasepool { try input.read(upToCount: Int(min(remaining, 4 << 20))) } ?? Data()
                    guard !slab.isEmpty else { throw EADownloadError.file("short read") }
                    remaining -= Int64(slab.count)
                    try inflater.write(slab, last: remaining == 0)
                }
                try inflater.write(Data(), last: true)
                inflatedOK = inflater.written == entry.uncompressedSize && inflater.crc.checksum == entry.crc32
                try? input.close(); try part.close()
                if !inflatedOK && useNative {
                    EALog.event("[ea-download] native inflate mismatch name=\(destination.lastPathComponent); decoding again")
                }
            } catch {
                try? input.close(); try? part.close()
                try? FileManager.default.removeItem(at: temporary)
                if error is CancellationError || !useNative { throw error }
            }
        }
        guard inflatedOK else {
            try? FileManager.default.removeItem(at: temporary)
            discardPartial()
            throw EADownloadError.file("checksum " + destination.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        discardPartial()
        return UInt64(total)
    }

    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            ?? (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
