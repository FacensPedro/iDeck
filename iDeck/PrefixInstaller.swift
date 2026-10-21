import Foundation
import Compression
import CryptoKit

class PrefixInstaller: ObservableObject {
    @Published var isInstalling: Bool = false
    @Published var progress: Float = 0.0

    private static let rootfsURL = URL(string: "https://raw.githubusercontent.com/FacensPedro/iDeck/main/madeira_env.zip")!

    /// Optional hex-encoded SHA-256 of the rootfs archive. When set, the download is
    /// rejected if its hash does not match. Can be overridden via UserDefaults ("rootfsSHA256").
    private var expectedSHA256: String? {
        let stored = UserDefaults.standard.string(forKey: "rootfsSHA256")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (stored?.isEmpty ?? true) ? nil : stored
    }

    private func finish(_ success: Bool, _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.isInstalling = false
            if success { self.progress = 1.0 }
            completion(success)
        }
    }

    func installWinePrefix(to destinationPath: String, completion: @escaping (Bool) -> Void) {
        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: destinationPath)
        let binPath = destinationURL.appendingPathComponent("usr/bin/box64").path

        if fileManager.fileExists(atPath: binPath) {
            DispatchQueue.main.async { completion(true) }
            return
        }

        DispatchQueue.main.async {
            self.isInstalling = true
            self.progress = 0.0
        }

        let task = URLSession.shared.downloadTask(with: PrefixInstaller.rootfsURL) { [weak self] localURL, response, error in
            guard let self = self else { return }

            guard let localURL = localURL, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.finish(false, completion)
                return
            }

            do {
                if let expected = self.expectedSHA256 {
                    let actual = try PrefixInstaller.sha256(of: localURL)
                    guard actual == expected else {
                        self.finish(false, completion)
                        return
                    }
                }

                DispatchQueue.main.async { self.progress = 0.5 }

                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                try ZipExtractor.extract(archive: localURL, to: destinationURL)

                // The install only counts if the translator binary is really there.
                self.finish(fileManager.fileExists(atPath: binPath), completion)
            } catch {
                self.finish(false, completion)
            }
        }
        task.resume()
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Minimal ZIP extractor (Process/unzip are unavailable on iOS)

enum ZipError: Error {
    case invalidArchive
    case unsupported
    case unsafePath
}

enum ZipExtractor {
    /// Extracts a ZIP archive (stored and deflate entries, no ZIP64, no encryption).
    /// Entries that would land outside `destination` (zip-slip) are rejected.
    static func extract(archive: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let lexicalRoot = destination.standardizedFileURL.path
        let resolvedRoot = destination.resolvingSymlinksInPath().standardizedFileURL.path

        guard let eocd = findEndOfCentralDirectory(data) else { throw ZipError.invalidArchive }
        let entryCount = try u16(data, eocd + 10)
        let directoryOffset = try u32(data, eocd + 16)
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF { throw ZipError.unsupported }

        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard try u32(data, cursor) == 0x0201_4b50 else { throw ZipError.invalidArchive }
            let flags = try u16(data, cursor + 8)
            let method = try u16(data, cursor + 10)
            let compressedSize = try u32(data, cursor + 20)
            let uncompressedSize = try u32(data, cursor + 24)
            let nameLength = try u16(data, cursor + 28)
            let extraLength = try u16(data, cursor + 30)
            let commentLength = try u16(data, cursor + 32)
            let externalAttributes = try u32(data, cursor + 38)
            let localOffset = try u32(data, cursor + 42)

            if flags & 1 != 0 { throw ZipError.unsupported } // encrypted
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.unsupported
            }

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZipError.invalidArchive }
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) else {
                throw ZipError.invalidArchive
            }
            cursor = nameStart + nameLength + extraLength + commentLength

            // Local header gives the real offset of the payload.
            guard try u32(data, localOffset) == 0x0403_4b50 else { throw ZipError.invalidArchive }
            let localName = try u16(data, localOffset + 26)
            let localExtra = try u16(data, localOffset + 28)
            let payloadStart = localOffset + 30 + localName + localExtra
            guard payloadStart + compressedSize <= data.count else { throw ZipError.invalidArchive }
            let payload = data.subdata(in: payloadStart..<(payloadStart + compressedSize))

            try writeEntry(name: name, method: method, payload: payload, uncompressedSize: uncompressedSize,
                           unixMode: externalAttributes >> 16, lexicalRoot: lexicalRoot,
                           resolvedRoot: resolvedRoot, destination: destination)
        }
    }

    private static func writeEntry(name: String, method: Int, payload: Data, uncompressedSize: Int,
                                   unixMode: Int, lexicalRoot: String, resolvedRoot: String, destination: URL) throws {
        let fm = FileManager.default

        // Reject absolute paths, backslashes and ".." components.
        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        if name.hasPrefix("/") || name.contains("\\") || components.contains("..") { throw ZipError.unsafePath }
        if components.isEmpty { return }

        let target = components.reduce(destination) { $0.appendingPathComponent(String($1)) }
        guard target.standardizedFileURL.path.hasPrefix(lexicalRoot + "/") else { throw ZipError.unsafePath }

        if name.hasSuffix("/") {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try ensureInside(target.resolvingSymlinksInPath(), root: resolvedRoot)
            return
        }

        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // A previously extracted symlink must not redirect the write outside the root.
        let resolvedParent = parent.resolvingSymlinksInPath()
        try ensureInside(resolvedParent, root: resolvedRoot)

        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }

        let fileType = unixMode & 0xF000
        if fileType == 0xA000 { // symbolic link
            guard method == 0, let linkTarget = String(data: payload, encoding: .utf8),
                  !linkTarget.hasPrefix("/") else { throw ZipError.unsafePath }
            let resolved = URL(fileURLWithPath: linkTarget, relativeTo: resolvedParent).standardizedFileURL
            try ensureInside(resolved, root: resolvedRoot)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
            return
        }

        switch method {
        case 0:
            guard payload.count == uncompressedSize else { throw ZipError.invalidArchive }
            guard fm.createFile(atPath: target.path, contents: payload) else { throw ZipError.invalidArchive }
        case 8:
            try inflate(payload, expectedSize: uncompressedSize, to: target)
        default:
            throw ZipError.unsupported
        }

        let permissions = unixMode & 0o777
        if permissions != 0 {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    private static func ensureInside(_ url: URL, root: String) throws {
        let path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { throw ZipError.unsafePath }
    }

    private static func inflate(_ input: Data, expectedSize: Int, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipError.invalidArchive }
        if expectedSize == 0 { return }
        guard !input.isEmpty else { throw ZipError.invalidArchive }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let bufferSize = 64 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { output.deallocate() }

        var stream = compression_stream(dst_ptr: output, dst_size: 0, src_ptr: UnsafePointer(output), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.invalidArchive
        }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw ZipError.invalidArchive }
            stream.src_ptr = base
            stream.src_size = input.count
            stream.dst_ptr = output
            stream.dst_size = bufferSize

            var written = 0
            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw ZipError.invalidArchive
                }

                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    written += produced
                    if written > expectedSize { throw ZipError.invalidArchive } // guards against zip bombs
                    try handle.write(contentsOf: Data(bytes: output, count: produced))
                } else if status == COMPRESSION_STATUS_OK && stream.src_size == 0 {
                    throw ZipError.invalidArchive // truncated stream, no progress possible
                }

                stream.dst_ptr = output
                stream.dst_size = bufferSize

                if status == COMPRESSION_STATUS_END {
                    guard written == expectedSize else { throw ZipError.invalidArchive }
                    return
                }
            }
        }
    }

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var index = data.count - 22
        while index >= lowest {
            if data[index] == 0x50, data[index + 1] == 0x4b, data[index + 2] == 0x05, data[index + 3] == 0x06 {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipError.invalidArchive }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipError.invalidArchive }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
    }
}
