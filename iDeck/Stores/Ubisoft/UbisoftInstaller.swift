// UbisoftInstaller.swift
// Split from UbisoftDownloader.swift (iDeck 3.0 architecture).

import Foundation
import CryptoKit

/// Checks each downloaded slice against the SHA-1 its manifest names it by. Ubisoft's
/// CDN files are named by a SHA-1 (slices_v3/x/<SHA1>), of the compressed bytes for most
/// products and of the plain bytes for some: the first slice that matches settles which,
/// for the whole install. If eight slices in a row match neither, the hashes are not
/// SHA-1 of the slice at all, and the check stands aside (logged once) instead of
/// stopping every download.
final class UbisoftSliceIntegrity: @unchecked Sendable {
    enum Basis { case unknown, compressed, plain, off }
    private let lock = NSLock()
    private var basis = Basis.unknown
    private var misses = 0
    private(set) var rejected = 0

    static func sha1(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: bytes)) }

    /// Whether the slice is the one the manifest names.
    func accepts(hash: [UInt8], compressed: [UInt8], plain: [UInt8]) -> Bool {
        guard hash.count == 20 else { return true }
        lock.lock(); let current = basis; lock.unlock()
        switch current {
        case .off: return true
        case .compressed, .plain:
            let ok = Self.sha1(current == .compressed ? compressed : plain) == hash
            if !ok { lock.lock(); rejected += 1; lock.unlock() }
            return ok
        case .unknown:
            let settled: Basis? = Self.sha1(compressed) == hash ? .compressed : Self.sha1(plain) == hash ? .plain : nil
            lock.lock(); defer { lock.unlock() }
            if let settled {
                if basis == .unknown {
                    basis = settled
                    AppLog.record("[ubisoft-download] slices checked against their SHA-1 (\(settled == .compressed ? "compressed" : "plain") bytes)")
                }
                return true
            }
            misses += 1
            if misses >= 8, basis == .unknown {
                basis = .off
                AppLog.record("[ubisoft-download] slice names are not the SHA-1 of the slice: the per-slice check is off for this install; file sizes are still checked")
            }
            return true
        }
    }
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
        // A file in the journal counts as finished only while it is on disk at its full
        // size: one deleted or cut short since (a full disk, a crash mid-write) is
        // downloaded again instead of being left broken.
        let journaled = Set(((try? String(contentsOf: journal, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        var finished = Set<String>()
        var broken = 0
        for file in manifest.files where journaled.contains(file.name) && !file.isDir {
            let size = (try? destination(file.name)).flatMap {
                (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.uint64Value
            }
            if size == file.size { finished.insert(file.name) } else { broken += 1 }
        }
        if broken > 0 {
            AppLog.record("[ubisoft-download] \(broken) installed file(s) missing or not at their size: downloaded again")
        }
        let integrity = UbisoftSliceIntegrity()
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
            var written: UInt64 = 0
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
                                let bytes = try await Self.fetch(url, slice: slice, compression: compression, integrity: integrity)
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
                        written += UInt64(bytes.count)
                        done += UInt64(bytes.count)
                        progress(Progress(done: min(done, manifest.totalBytes), total: manifest.totalBytes))
                    }
                }
            }
            // The slices must make up the whole file: a short file would be padded with
            // zeros by the truncate below and the game would read garbage.
            if file.size > 0, written < file.size {
                AppLog.record("[ubisoft-download] \(file.name): \(written) of \(file.size) bytes from its slices")
                throw UbisoftDemuxError.malformed("file \(file.name) incomplete")
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

    static func fetch(_ url: URL, slice: UbisoftManifest.Slice, compression: UbisoftManifest.Compression,
                      integrity: UbisoftSliceIntegrity? = nil) async throws -> [UInt8] {
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
                let out: [UInt8]
                switch compression {
                case .none: out = raw
                case .zstd:
                    guard let inflated = UbisoftInflate.zstd(raw, expected: expected > 0 ? expected : max(raw.count * 8, 1 << 20)) else {
                        throw UbisoftDemuxError.malformed("zstd slice")
                    }
                    out = inflated
                case .deflate:
                    guard let inflated = UbisoftInflate.zlib(raw, expected: expected) ?? UbisoftInflate.zlib(raw, raw: true, expected: expected) else {
                        throw UbisoftDemuxError.malformed("deflate slice")
                    }
                    out = inflated
                case .lzham:
                    switch UbisoftInflate.lzham(raw, expected: expected) {
                    case .success(let inflated): out = inflated
                    case .failure(let failure):
                        AppLog.record("[ubisoft-download] LZHAM slice failed: status \(failure.status), \(raw.count) bytes in, \(expected) expected")
                        throw UbisoftDemuxError.malformed("LZHAM slice")
                    }
                }
                // A slice whose content is not the one named (a cut transfer, a bad cache in
                // between) is downloaded again, up to four times, instead of being written.
                if let integrity, !integrity.accepts(hash: slice.hash, compressed: raw, plain: out) {
                    AppLog.record("[ubisoft-download] slice \(UbisoftManifest.slicePath(slice.hash)) does not match its SHA-1: downloaded again")
                    throw UbisoftDemuxError.refused("slice SHA-1 mismatch")
                }
                return out
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
