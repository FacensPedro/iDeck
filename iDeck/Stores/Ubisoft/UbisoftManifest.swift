// UbisoftManifest.swift
// Split from UbisoftDownloader.swift (iDeck 3.0 architecture).

import Foundation

/// The few things iDeck reads from a product's configuration (YAML text).
enum UbisoftConfiguration {
    /// root › name; a localized name ("l1") is looked up in localizations › default.
    static func name(_ yaml: String) -> String? {
        let lines = yaml.components(separatedBy: .newlines)
        var inRoot = false
        var raw: String?
        for line in lines {
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { inRoot = line.hasPrefix("root:") ; continue }
            guard inRoot else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only root's own "name:", two spaces in.
            if line.hasPrefix("  name:") && !line.hasPrefix("   ") {
                raw = unquote(String(trimmed.dropFirst("name:".count)))
                break
            }
        }
        guard var name = raw, !name.isEmpty else { return nil }
        if name.range(of: "^l[0-9]+$", options: .regularExpression) != nil {
            var inLocalizations = false, inDefault = false
            for line in lines {
                if !line.hasPrefix(" ") { inLocalizations = line.hasPrefix("localizations:"); inDefault = false; continue }
                guard inLocalizations else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("  ") && !line.hasPrefix("   ") { inDefault = trimmed.hasPrefix("default:"); continue }
                if inDefault, trimmed.hasPrefix(name + ":") {
                    name = unquote(String(trimmed.dropFirst(name.count + 1)))
                    break
                }
            }
        }
        return name.isEmpty || name.range(of: "^l[0-9]+$", options: .regularExpression) != nil ? nil : name
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// A download manifest (mg.protocol.download.Manifest), only what installing needs.
struct UbisoftManifest: Sendable {
    struct Slice: Sendable { let hash: [UInt8]; let size: UInt64; let offset: UInt64? }
    struct File: Sendable { let name: String; let size: UInt64; let isDir: Bool; let slices: [Slice] }

    enum Compression: UInt64, Sendable { case none = 0, deflate = 1, lzham = 2, zstd = 3 }

    var files: [File] = []
    var compression: Compression = .none
    var languages: Set<String> = []

    var totalBytes: UInt64 { files.reduce(0) { $0 + ($1.isDir ? 0 : $1.size) } }

    /// The file as the CDN serves it: a 356-byte header, then the zlib-compressed message.
    static func parse(_ data: Data, language: String) throws -> UbisoftManifest {
        let bytes = [UInt8](data)
        var message: [UInt8]?
        for skip in [356, 0] where bytes.count > skip {
            if let inflated = UbisoftInflate.zlib(Array(bytes[skip...])) { message = inflated; break }
        }
        guard let message, let root = try? GalaxyFields(message) else { throw UbisoftDemuxError.malformed("manifest") }
        var manifest = UbisoftManifest()
        let compressed = root.bool(17) ?? true
        manifest.compression = compressed ? Compression(rawValue: root.uint(21) ?? 1) ?? .deflate : .none
        var chosen: [UbisoftManifest.File] = []
        for (number, field) in root.fields where number == 4 {
            guard case let .bytes(raw) = field, let chunk = try? GalaxyFields(raw) else { continue }
            let required = (chunk.uint(2) ?? 0) == 0
            let chunkLanguage = chunk.string(5) ?? ""
            if !chunkLanguage.isEmpty { manifest.languages.insert(chunkLanguage) }
            // Required chunks, and the language chunk for the chosen language.
            guard (required && chunkLanguage.isEmpty) || chunkLanguage.lowercased() == language.lowercased() else { continue }
            for (n, f) in chunk.fields where n == 3 {
                guard case let .bytes(fileRaw) = f, let file = try? GalaxyFields(fileRaw), let name = file.string(1) else { continue }
                let hashes = file.fields.compactMap { k, v -> [UInt8]? in if k == 4, case let .bytes(b) = v { return b } else { return nil } }
                let list = file.fields.compactMap { k, v -> GalaxyFields? in
                    if k == 7, case let .bytes(b) = v { return try? GalaxyFields(b) } else { return nil }
                }
                var slices: [Slice] = []
                if !list.isEmpty {
                    for (index, slice) in list.enumerated() {
                        guard let hash = slice.data(3) ?? (index < hashes.count ? hashes[index] : nil) else { continue }
                        slices.append(Slice(hash: hash, size: slice.uint(1) ?? 0, offset: slice.uint(4)))
                    }
                } else {
                    slices = hashes.map { Slice(hash: $0, size: 0, offset: nil) }
                }
                chosen.append(File(name: name.replacingOccurrences(of: "\\", with: "/"), size: file.uint(2) ?? 0,
                                   isDir: file.bool(3) ?? false, slices: slices))
            }
        }
        // A language-free install still needs a language when every chunk has one.
        if chosen.allSatisfy(\.isDir), language.lowercased() != "en-us" {
            return try parse(data, language: "en-US")
        }
        manifest.files = chosen
        return manifest
    }

    /// The CDN path of a slice: slices_v3/<one base-32 character>/<SHA1 in upper hex>.
    static func slicePath(_ hash: [UInt8]) -> String {
        let hex = hash.map { String(format: "%02X", $0) }.joined()
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
        let chars = Array(hex)
        guard chars.count >= 2, let value = UInt8(String([chars[1], chars[0]]), radix: 16) else { return "slices_v3/0/" + hex }
        let index = Int(value / 16) + (value % 2 == 0 ? 0 : 16)
        return "slices_v3/\(alphabet[index])/\(hex)"
    }
}

enum UbisoftInflate {
    /// zlib-wrapped or raw deflate data, inflated whole by the app's C codec
    /// (ZipNative.c). A zlib stream's 2-byte header is skipped; its Adler-32 is not checked.
    static func zlib(_ input: [UInt8], raw: Bool = false, expected: Int = 0) -> [UInt8]? {
        var body = input
        if !raw {
            guard input.count > 2, input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0,
                  input[1] & 0x20 == 0 else { return nil }
            body = Array(input[2...])
        }
        var capacity = expected > 0 ? expected : max(body.count * 8, 1 << 16)
        while capacity <= 1 << 28 {   // manifests are a few MB; stop well before memory runs out
            var output = [UInt8](repeating: 0, count: capacity)
            var produced = 0
            let result = body.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    ideck_zip_inflate_raw(src.baseAddress, src.count, dst.baseAddress, dst.count, &produced, nil)
                }
            }
            if result == Int32(IDECK_ZIP_OK) {
                output.removeSubrange(produced...)
                return output
            }
            // Too small an output (or a corrupt stream): a known size is final.
            if expected > 0 { return nil }
            capacity *= 4
        }
        return nil
    }

    static func zstd(_ input: [UInt8], expected: Int) -> [UInt8]? {
        guard expected > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: expected)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in zstd_safe_decompress(dst.baseAddress, expected, src.baseAddress, input.count) }
        }
        guard written >= 0, written <= expected else { return nil }   // (size_t)-1 is an error
        output.removeSubrange(written...)
        return output
    }

    /// LZHAM 1.x through the app's C++ codec (LzhamCodec.cpp, Vendor/LZHAM). Ubisoft
    /// writes slices as LZHAM zlib streams with a 2^15 dictionary (as UplayDB's
    /// UplayApps reads them); the codec takes the dictionary size from the stream's
    /// header and checks its Adler-32. Returns the bytes, or the codec's status on failure.
    static func lzham(_ input: [UInt8], expected: Int) -> Result<[UInt8], LzhamFailure> {
        var capacity = expected > 0 ? expected : max(input.count * 8, 1 << 20)
        while true {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    ideck_lzham_decompress(src.baseAddress, src.count, dst.baseAddress, dst.count, 15)
                }
            }
            if written >= 0 {
                output.removeSubrange(Int(written)...)
                return .success(output)
            }
            // Without a known size, a too-small buffer ends as DEST_BUF_TOO_SMALL (5) or,
            // in LZHAM's unbuffered mode, BAD_CODE (7): grow and try again.
            if written == -5 || written == -7, expected <= 0, capacity < 1 << 28 { capacity *= 4; continue }
            return .failure(LzhamFailure(status: Int(-written)))
        }
    }

    struct LzhamFailure: Error { let status: Int }
}
