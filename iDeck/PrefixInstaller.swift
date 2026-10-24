import Foundation
import Compression
import CryptoKit

class PrefixInstaller: ObservableObject {
    @Published var isInstalling: Bool = false
    @Published var progress: Float = 0.0

    /// Wine prefix skeleton (registry + directory layout) produced by the Madeira project
    /// (https://github.com/willfaust/madeira, tools/build-prefix-snapshot.sh). The URL is
    /// pinned to a commit and the archive is verified against a SHA-256, so the file can
    /// not change underneath us. Madeira is GPL-3.0: check its license before redistributing.
    private static let templateURL = URL(string:
        "https://raw.githubusercontent.com/willfaust/madeira/279fd0f83170425db002fe25d6bd62f6355f497d/app/Madeira/prefix-template.tar.gz")!
    private static let templateSHA256 = "7fe642c4e07910d5956e43bac243e01fd079c271391f22283dd1e377e876cc9f"

    /// The archive has a single top-level "prefix/" directory that is stripped on extraction.
    private static let archiveRoot = "prefix"

    private func finish(_ success: Bool, _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.isInstalling = false
            if success { self.progress = 1.0 }
            completion(success)
        }
    }

    /// A prefix is considered installed once wineboot's marker and the registry exist.
    static func isPrefixInstalled(at destination: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: destination.appendingPathComponent(".update-timestamp").path)
            && fm.fileExists(atPath: destination.appendingPathComponent("system.reg").path)
            && fm.fileExists(atPath: destination.appendingPathComponent("drive_c/windows").path)
    }

    func installWinePrefix(to destinationPath: String, completion: @escaping (Bool) -> Void) {
        let destinationURL = URL(fileURLWithPath: destinationPath)

        if PrefixInstaller.isPrefixInstalled(at: destinationURL) {
            DispatchQueue.main.async { completion(true) }
            return
        }

        DispatchQueue.main.async {
            self.isInstalling = true
            self.progress = 0.0
        }

        let task = URLSession.shared.downloadTask(with: PrefixInstaller.templateURL) { [weak self] localURL, response, error in
            guard let self = self else { return }

            guard let localURL = localURL, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.finish(false, completion)
                return
            }

            do {
                guard try PrefixInstaller.sha256(of: localURL) == PrefixInstaller.templateSHA256 else {
                    print("PrefixInstaller: checksum mismatch, refusing to install")
                    self.finish(false, completion)
                    return
                }
                DispatchQueue.main.async { self.progress = 0.5 }

                try TarGzExtractor.extract(archive: localURL, to: destinationURL, stripping: PrefixInstaller.archiveRoot)
                try PrefixInstaller.createDosDevices(in: destinationURL)

                self.finish(PrefixInstaller.isPrefixInstalled(at: destinationURL), completion)
            } catch {
                print("PrefixInstaller: install failed: \(error)")
                self.finish(false, completion)
            }
        }
        task.resume()
    }

    /// The template ships without dosdevices (a "z:" -> "/" link would be wrong on iOS).
    /// Only the C: drive is created, pointing at drive_c inside the prefix.
    private static func createDosDevices(in prefix: URL) throws {
        let fm = FileManager.default
        let dosdevices = prefix.appendingPathComponent("dosdevices")
        try fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        let link = dosdevices.appendingPathComponent("c:")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../drive_c")
        }
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

// MARK: - tar.gz extractor

enum TarGzExtractor {
    private static let maxUncompressedSize = 1 << 30 // 1 GiB

    /// Extracts a gzip-compressed ustar/pax archive. `stripping` removes one leading directory.
    /// Supports files, directories and relative symlinks; anything escaping `destination` is rejected.
    static func extract(archive: URL, to destination: URL, stripping root: String?) throws {
        let tar = try gunzip(Data(contentsOf: archive, options: .alwaysMapped))
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let lexicalRoot = destination.standardizedFileURL.path
        let resolvedRoot = destination.resolvingSymlinksInPath().standardizedFileURL.path

        var offset = 0
        var overrideName: String?
        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            offset += 512

            guard let size = parseOctal(header, 124, 12) else { throw ZipError.invalidArchive }
            let type = header[156]
            let paddedSize = (size + 511) / 512 * 512
            guard offset + size <= tar.count else { throw ZipError.invalidArchive }
            let body = tar.subdata(in: offset..<(offset + size))
            offset += min(paddedSize, tar.count - offset)

            // pax extended header ('x') or GNU long name ('L') carry the next entry's real path.
            if type == UInt8(ascii: "x") {
                overrideName = paxPath(body)
                continue
            }
            if type == UInt8(ascii: "L") {
                overrideName = cString(body)
                continue
            }
            if type == UInt8(ascii: "g") { continue }

            var name = overrideName ?? ustarName(header)
            overrideName = nil

            if let root = root {
                if name == root || name == root + "/" { continue }
                if name.hasPrefix(root + "/") { name = String(name.dropFirst(root.count + 1)) }
            }
            // Skip macOS AppleDouble metadata files.
            if name.split(separator: "/").contains(where: { $0.hasPrefix("._") }) { continue }

            let mode = parseOctal(header, 100, 8) ?? 0
            try writeEntry(name: name, type: type, body: body, mode: mode, header: header,
                           lexicalRoot: lexicalRoot, resolvedRoot: resolvedRoot, destination: destination)
        }
    }

    private static func writeEntry(name: String, type: UInt8, body: Data, mode: Int, header: Data,
                                   lexicalRoot: String, resolvedRoot: String, destination: URL) throws {
        let fm = FileManager.default
        let components = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if name.hasPrefix("/") || name.contains("\\") || components.contains("..") { throw ZipError.unsafePath }
        if components.isEmpty { return }

        let target = components.reduce(destination) { $0.appendingPathComponent(String($1)) }
        guard target.standardizedFileURL.path.hasPrefix(lexicalRoot + "/") else { throw ZipError.unsafePath }

        let isDirectory = type == UInt8(ascii: "5") || (type == 0 && name.hasSuffix("/"))
        if isDirectory {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try ZipExtractor.ensureInside(target.resolvingSymlinksInPath(), root: resolvedRoot)
            return
        }

        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let resolvedParent = parent.resolvingSymlinksInPath()
        try ZipExtractor.ensureInside(resolvedParent, root: resolvedRoot)

        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.removeItem(at: target)
        }

        switch type {
        case UInt8(ascii: "0"), 0:
            guard fm.createFile(atPath: target.path, contents: body) else { throw ZipError.invalidArchive }
            let permissions = mode & 0o777
            if permissions != 0 {
                try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
        case UInt8(ascii: "2"): // symlink
            let linkTarget = cString(header.subdata(in: 157..<257))
            guard !linkTarget.isEmpty, !linkTarget.hasPrefix("/") else { throw ZipError.unsafePath }
            let resolved = URL(fileURLWithPath: linkTarget, relativeTo: resolvedParent).standardizedFileURL
            try ZipExtractor.ensureInside(resolved, root: resolvedRoot)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
        default:
            break // hard links, devices, fifos: not needed, ignored
        }
    }

    // MARK: tar helpers

    private static func cString(_ data: Data) -> String {
        let end = data.firstIndex(of: 0) ?? data.endIndex
        return String(decoding: data[data.startIndex..<end], as: UTF8.self)
    }

    private static func ustarName(_ header: Data) -> String {
        let base = cString(header.subdata(in: 0..<100))
        // POSIX ustar stores long paths as prefix (offset 345) + "/" + name.
        if header.subdata(in: 257..<262) == Data("ustar".utf8) {
            let prefix = cString(header.subdata(in: 345..<500))
            if !prefix.isEmpty { return prefix + "/" + base }
        }
        return base
    }

    private static func paxPath(_ body: Data) -> String? {
        // Records look like "<len> key=value\n".
        var index = body.startIndex
        while index < body.endIndex {
            guard let space = body[index...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: body[index..<space], as: UTF8.self)),
                  length > 0, index + length <= body.endIndex else { return nil }
            let record = String(decoding: body[(space + 1)..<(index + length - 1)], as: UTF8.self)
            if record.hasPrefix("path=") { return String(record.dropFirst(5)) }
            index += length
        }
        return nil
    }

    private static func parseOctal(_ header: Data, _ offset: Int, _ length: Int) -> Int? {
        var value = 0
        for byte in header.subdata(in: offset..<(offset + length)) {
            if byte == 0 || byte == 0x20 { continue }
            guard byte >= 0x30, byte <= 0x37 else { return nil }
            value = (value << 3) | Int(byte - 0x30)
        }
        return value
    }

    // MARK: gzip

    /// Strips the gzip wrapper and inflates the raw deflate stream (Apple's COMPRESSION_ZLIB is raw deflate).
    private static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else { throw ZipError.invalidArchive }
        let flags = data[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= data.count else { throw ZipError.invalidArchive }
            index += 2 + Int(data[index]) + (Int(data[index + 1]) << 8)
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 { // FNAME, FCOMMENT
            guard let end = data[index...].firstIndex(of: 0) else { throw ZipError.invalidArchive }
            index = end + 1
        }
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index < data.count - 8 else { throw ZipError.invalidArchive }

        let deflated = data.subdata(in: index..<(data.count - 8)) // drop CRC32 + ISIZE trailer
        let expected = Int(data[data.count - 4]) | (Int(data[data.count - 3]) << 8)
            | (Int(data[data.count - 2]) << 16) | (Int(data[data.count - 1]) << 24)
        guard expected <= maxUncompressedSize else { throw ZipError.unsupported }

        var output = Data()
        output.reserveCapacity(expected)
        try inflate(deflated, limit: maxUncompressedSize) { output.append($0) }
        return output
    }

    private static func inflate(_ input: Data, limit: Int, sink: (Data) -> Void) throws {
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.invalidArchive
        }
        defer { compression_stream_destroy(&stream) }

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Void in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw ZipError.invalidArchive }
            stream.src_ptr = base
            stream.src_size = input.count
            stream.dst_ptr = buffer
            stream.dst_size = bufferSize

            var total = 0
            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw ZipError.invalidArchive
                }
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    total += produced
                    if total > limit { throw ZipError.invalidArchive }
                    sink(Data(bytes: buffer, count: produced))
                } else if status == COMPRESSION_STATUS_OK && stream.src_size == 0 {
                    throw ZipError.invalidArchive
                }
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                if status == COMPRESSION_STATUS_END { return }
            }
        }
    }
}

// MARK: - Minimal ZIP extractor (Process/unzip are unavailable on iOS)

enum ZipError: Error {
    case unsafePathEntry(String)
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

            // Non-payload ZIP metadata (macOS AppleDouble, metadata plists,
            // resource forks) should never be extracted or permitted to
            // invalidate an otherwise safe IPA bundle.
            let components = name.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: true)
                .filter { $0 != "." }
            guard components.first == "Payload" else { continue }
            // AppleDouble files, macOS ZIP metadata and Finder thumbnails are
            // not part of an iOS app. Skip them without relaxing path checks
            // for executable/resource files inside Payload.
            if components.contains(where: {
                $0 == "__MACOSX" || $0 == ".DS_Store" ||
                $0.hasPrefix("._") || $0 == ".Spotlight-V100"
            }) { continue }

            // Local header gives the real offset of the payload.
            guard try u32(data, localOffset) == 0x0403_4b50 else { throw ZipError.invalidArchive }
            let localName = try u16(data, localOffset + 26)
            let localExtra = try u16(data, localOffset + 28)
            let payloadStart = localOffset + 30 + localName + localExtra
            guard payloadStart + compressedSize <= data.count else { throw ZipError.invalidArchive }
            let payload = data.subdata(in: payloadStart..<(payloadStart + compressedSize))

            do {
                try writeEntry(name: name, method: method, payload: payload, uncompressedSize: uncompressedSize,
                               unixMode: externalAttributes >> 16, lexicalRoot: lexicalRoot,
                               resolvedRoot: resolvedRoot, destination: destination)
            } catch ZipError.unsafePath {
                let safeLabel = name.unicodeScalars.prefix(160).map {
                    $0.value >= 0x20 && $0.value != 0x7f ? String($0) : "?"
                }.joined()
                throw ZipError.unsafePathEntry(safeLabel)
            }
        }
    }

    private static func writeEntry(name: String, method: Int, payload: Data, uncompressedSize: Int,
                                   unixMode: Int, lexicalRoot: String, resolvedRoot: String, destination: URL) throws {
        let fm = FileManager.default

        guard let safeComponents = IPAArchivePath.components(name) else {
            throw ZipError.unsafePath
        }
        if safeComponents.count == 1 { return }
        let target = safeComponents.reduce(destination) { $0.appendingPathComponent($1) }
        let standardizedTarget = target.standardizedFileURL.path
        guard standardizedTarget.hasPrefix(lexicalRoot + "/") else { throw ZipError.unsafePath }

        // Directory records carry no payload. Deferring directory creation until
        // a real file or symlink is extracted also avoids a false iPadOS
        // path-resolution failure on entries like Payload/GetMoreRam.app/.
        // Parents are checked for escaping symlinks immediately before writes.
        if IPAArchivePath.isDirectory(name, unixMode: unixMode) {
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
        if fileType != 0 && fileType != 0x8000 && fileType != 0xA000 {
            throw ZipError.unsafePath
        }
        if fileType == 0xA000 { // symbolic link
            guard method == 0, let linkTarget = String(data: payload, encoding: .utf8),
                  !linkTarget.hasPrefix("/") else { throw ZipError.unsafePath }
            let resolved = URL(fileURLWithPath: linkTarget, relativeTo: resolvedParent)
                .standardizedFileURL.resolvingSymlinksInPath()
            try ensureInside(resolved, root: resolvedRoot)
            let appRoot = destination
                .appendingPathComponent("Payload", isDirectory: true)
                .appendingPathComponent(safeComponents[1], isDirectory: true)
                .resolvingSymlinksInPath()
            try ensureInside(resolved, root: appRoot.path)
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

    static func ensureInside(_ url: URL, root: String) throws {
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

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Void in
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
