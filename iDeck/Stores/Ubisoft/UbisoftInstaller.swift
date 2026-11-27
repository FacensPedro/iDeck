// UbisoftInstaller.swift
// Split from UbisoftDownloader.swift (iDeck 3.0 architecture).

import Foundation

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
