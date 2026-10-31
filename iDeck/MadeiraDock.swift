// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Dock for iDeck: start an installed Steam game through Valve's
// genuine Windows Steam client, without its desktop window.
// SteamRuntimeFiles/SteamRuntimeInstaller and MadeiraDock are ported from
// Madeira's SteamRuntime.swift and MadeiraDock.swift
// (GPL-3.0-or-later, Copyright 2026 125hz, Madeira Converter Exception).
// dockhost.exe is built from the madeira-dock submodule by
// scripts/build_madeira_dock.sh into the bundle's arm64ec-windows folder.

import Foundation
import Network
import zlib
#if canImport(CryptoKit)
import CryptoKit
#endif

// Valve's client components for Madeira Dock, fetched from Valve's own update
// CDN (one host, HTTPS) and checked against pinned sizes and SHA-256 sums; the
// unpacked steamclient64.dll must be the client build the Dock host supports.
// Pins never follow a moving client manifest. No Valve binary is bundled.
enum SteamRuntimeFiles {
    struct Package: Sendable {
        let file: String
        let bytes: Int
        let sha256: String
    }
    static let origin = "https://client-update.akamai.steamstatic.com/"
    static let packages = [
        Package(file: "bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da", bytes: 59_544_006,
                sha256: "8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62"),
        Package(file: "bins_win64_win32.zip.f29d67dc38a4be027f1734802697c668621a6da1", bytes: 10_509_550,
                sha256: "345f6e4bdc19b27ae53bf752c21e2d894e0e899d94823222fb426e890d1226b5"),
        Package(file: "steam_win32.zip.3e96965d109fc2d4cc14206b2fc4ec960a746ed3", bytes: 2_307_664,
                sha256: "1369615c795b60de822876b4dc4042186cf58d0dc8f63ea1371167f667e16925")
    ]
    static let clientSHA256 = "71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640"
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"

    enum Failure: LocalizedError {
        case invalidPackage, conflict, activeSession, prefixMissing
        var errorDescription: String? {
            switch self {
            case .invalidPackage: return "Steam's components could not be verified. Try downloading them again."
            case .conflict: return "Existing Steam files need attention. They were kept. Use the desktop setup option."
            case .activeSession: return "Close the running session before preparing Steam's components."
            case .prefixMissing: return "Prepare the Windows environment first: start any Windows program once."
            }
        }
    }

    static func validPath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < 240,
              !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ") }
    }

    static func destination(_ relative: String, under drive: URL) throws -> URL {
        guard validPath(relative) else { throw Failure.conflict }
        let fm = FileManager.default
        var result = drive
        for component in relative.split(separator: "/") {
            if fm.fileExists(atPath: result.path) {
                let matches = try fm.contentsOfDirectory(atPath: result.path)
                    .filter { $0.caseInsensitiveCompare(String(component)) == .orderedSame }
                guard matches.isEmpty || matches == [String(component)] else { throw Failure.conflict }
            }
            result.appendPathComponent(String(component))
            guard result.standardizedFileURL.path == result.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw Failure.conflict
            }
        }
        return result
    }

    // Parse the central directory, then validate each local header. ZIP64,
    // encryption, symlinks and duplicate/case-colliding names are rejected.
    // Called only AFTER the whole archive's pinned SHA-256 has been checked.
    static func unpack(_ data: Data, write: (String, Data) throws -> Void) throws {
        func need(_ condition: Bool) throws { if !condition { throw Failure.invalidPackage } }
        try need(data.count >= 22 && data.count <= 64 * 1024 * 1024)
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1)
            .first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count }) else {
            throw Failure.invalidPackage
        }
        let count = u16(end + 10), central = u32(end + 16), centralSize = u32(end + 12)
        try need(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == count && count <= 256)
        try need(central <= end && centralSize == end - central)
        var cursor = central, total = 0
        var seen = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            try need(cursor + 46 <= end && u32(cursor) == 0x02014b50)
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let crc = UInt32(u32(cursor + 16)), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), local = u32(cursor + 42)
            let next = cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
            let kind = (u32(cursor + 38) >> 16) & 0xf000
            try need(next <= end && flags & 1 == 0 && (method == 0 || method == 8))
            try need(kind == 0 || kind == 0x8000 || kind == 0x4000)
            guard let rawName = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8) else {
                throw Failure.invalidPackage
            }
            // Valve's Windows packages use backslashes. Normalize BEFORE all
            // traversal/duplicate checks, but compare local headers verbatim.
            let normalizedName = rawName.replacingOccurrences(of: "\\", with: "/")
            let directory = normalizedName.hasSuffix("/")
            let name = directory ? String(normalizedName.dropLast()) : normalizedName
            try need(validPath(name) && seen.insert(name.lowercased()).inserted)
            try need(size <= 64 * 1024 * 1024 && local + 30 <= central && u32(local) == 0x04034b50)
            try need(u16(local + 6) == flags && u16(local + 8) == method && u16(local + 26) == nameLength)
            let body = local + 30 + nameLength + u16(local + 28)
            try need(body <= central && compressed <= central - body)
            try need(data.subdata(in: local + 30..<local + 30 + nameLength) == Data(rawName.utf8))
            if flags & 8 == 0 { try need(u32(local + 18) == compressed && u32(local + 22) == size) }
            total += size
            try need(total <= 256 * 1024 * 1024)
            if directory { try need(size == 0 && compressed == 0); cursor = next; continue }
            let encoded = data.subdata(in: body..<body + compressed)
            var decoded: Data
            if method == 0 {
                try need(compressed == size); decoded = encoded
            } else {
                decoded = Data(count: max(size, 1))
                var stream = z_stream(), valid = false
                encoded.withUnsafeBytes { source in
                    decoded.withUnsafeMutableBytes { destination in
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                        stream.avail_in = UInt32(compressed)
                        stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                        stream.avail_out = UInt32(max(size, 1))
                        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                        let result = inflate(&stream, Z_FINISH)
                        valid = result == Z_STREAM_END && stream.total_in == compressed && stream.total_out == size
                        inflateEnd(&stream)
                    }
                }
                try need(valid); decoded.count = size
            }
            let actualCRC = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(size)) }
            try need(UInt32(actualCRC) == crc)
            try write(name, decoded)
            cursor = next
        }
        try need(cursor == end)
    }

    /// The registry value or file that stopped the last setup, for the log.
    nonisolated(unsafe) static var lastConflict: String?

    /// A REG_SZ line's value, unescaped ("C:\\\\Steam" in the hive is C:\Steam), or nil.
    static func stringValue(_ line: String, after prefix: String) -> String? {
        let rest = line.dropFirst(prefix.count)
        guard rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 else { return nil }
        return String(rest.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\\", with: "\u{0}").replacingOccurrences(of: "\u{0}", with: "\\")
    }

    // Only fixed client-discovery paths are written. Never write user IDs,
    // licenses, login cache, tokens, or a value asserting ownership.
    // - stale: whether a value already there names a Steam client that is not
    //   on the drive (a C:\ path, unescaped). A Steam emulator shipped with a
    //   game, or a client removed since, leaves SteamPath / SteamClientDll64
    //   pointing at a folder without Steam: such a value is replaced (both hives
    //   keep their .dock-setup-bak copy), and any other differing value is kept.
    static func registry(_ text: String, machine: Bool, stale: (String) -> Bool = { _ in false }) throws -> String {
        guard text.hasPrefix("WINE REGISTRY Version 2") else { throw Failure.prefixMissing }
        let root = windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
        let sections: [(String, [(String, String)])] = machine
            ? [("Software\\\\Valve\\\\Steam", [("InstallPath", root)]),
               ("Software\\\\Wow6432Node\\\\Valve\\\\Steam", [("InstallPath", root)])]
            : [("Software\\\\Valve\\\\Steam", [("SteamPath", root), ("SteamExe", root + "\\\\steam.exe")]),
               ("Software\\\\Valve\\\\Steam\\\\ActiveProcess",
                [("SteamClientDll", root + "\\\\steamclient.dll"), ("SteamClientDll64", root + "\\\\steamclient64.dll")])]
        var lines = text.components(separatedBy: "\n")
        for (key, values) in sections {
            let header = "[\(key)]"
            let starts = lines.indices.filter { lines[$0].lowercased().hasPrefix(header.lowercased()) }
            guard starts.count <= 1 else { throw Failure.conflict }
            if let start = starts.first {
                let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
                var additions: [String] = []
                for (name, value) in values {
                    let prefix = "\"\(name)\"="
                    let found = lines[(start + 1)..<end].indices.filter { lines[$0].lowercased().hasPrefix(prefix.lowercased()) }
                    let expected = prefix + "\"\(value)\""
                    if found.count == 1, lines[found[0]] != expected, let old = stringValue(lines[found[0]], after: prefix),
                       stale(old) {
                        lines[found[0]] = expected
                        continue
                    }
                    guard found.isEmpty || found.map({ lines[$0] }) == [expected] else {
                        lastConflict = "\(key)\\\(name)"
                        throw Failure.conflict
                    }
                    if found.isEmpty { additions.append(expected) }
                }
                lines.insert(contentsOf: additions, at: end)
            } else {
                lines += ["", header] + values.map { "\"\($0.0)\"=\"\($0.1)\"" } + [""]
            }
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(CryptoKit)
private final class SteamRuntimeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "client-update.akamai.steamstatic.com"
            && (url?.port == nil || url?.port == 443) && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

actor SteamRuntimeInstaller {
    static let shared = SteamRuntimeInstaller()
    private var busy = false

    // Runs before any Wine session in this app run; no Wine/JIT run.
    func prepare(prefix: URL, progress: @Sendable (String) async -> Void) async throws {
        guard !busy, !ideck_wineprocess_running(), !ideck_wineserver_running() else {
            throw SteamRuntimeFiles.Failure.activeSession
        }
        busy = true; defer { busy = false }
        SteamRuntimeFiles.lastConflict = nil
        let fm = FileManager.default
        // iDeck's prefix comes from its own template (PrefixInstaller); the
        // registry hives must exist before the discovery values are added.
        guard ["system.reg", "user.reg"].allSatisfy({ fm.fileExists(atPath: prefix.appendingPathComponent($0).path) }) else {
            throw SteamRuntimeFiles.Failure.prefixMissing
        }
        let drive = prefix.appendingPathComponent("drive_c")
        let root = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            SteamRuntimeFiles.lastConflict = "a linked Steam folder"
            throw SteamRuntimeFiles.Failure.conflict
        }
        // Existing installs are retained; this trial prepares missing files.
        if fm.fileExists(atPath: root.appendingPathComponent("steam.exe").path) {
            // Already prepared (or a desktop Steam install of the supported build).
            if MadeiraDock.clientSupported { await progress("Steam components are ready."); return }
            SteamRuntimeFiles.lastConflict = "steam.exe already there"
            throw SteamRuntimeFiles.Failure.conflict
        }
        let stage = fm.temporaryDirectory.appendingPathComponent("ideck-steam-runtime-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: SteamRuntimeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var names = Set<String>(), files: [String] = []
        for (index, package) in SteamRuntimeFiles.packages.enumerated() {
            try Task.checkCancellation()
            await progress("Downloading Steam components (\(index + 1) of \(SteamRuntimeFiles.packages.count))…")
            let url = URL(string: SteamRuntimeFiles.origin + package.file)!
            let (temporary, response) = try await session.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == url.host, http.url?.scheme == "https",
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                throw SteamRuntimeFiles.Failure.invalidPackage
            }
            let archive = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard Self.hash(archive) == package.sha256 else { throw SteamRuntimeFiles.Failure.invalidPackage }
            await progress("Verifying Steam components…")
            try SteamRuntimeFiles.unpack(archive) { name, bytes in
                guard names.insert(name.lowercased()).inserted else { throw SteamRuntimeFiles.Failure.invalidPackage }
                let file = stage.appendingPathComponent(name)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
                files.append(name)
            }
        }
        guard Self.hash(try Data(contentsOf: stage.appendingPathComponent("steamclient64.dll"))) == SteamRuntimeFiles.clientSHA256,
              files.contains("steam.exe") else { throw SteamRuntimeFiles.Failure.invalidPackage }
        try Task.checkCancellation()
        guard !ideck_wineprocess_running(), !ideck_wineserver_running() else { throw SteamRuntimeFiles.Failure.activeSession }
        await progress("Preparing the Windows environment…")
        try Task.checkCancellation()
        guard !ideck_wineprocess_running(), !ideck_wineserver_running() else { throw SteamRuntimeFiles.Failure.activeSession }
        // Preflight all destinations and both hives before publishing anything.
        // A discovery value naming a C:\ folder (or a file in one) without steam.exe
        // points at no Steam client: an emulator's or a removed client's leftover.
        let stale: (String) -> Bool = { value in
            guard value.lowercased().hasPrefix("c:\\") else { return false }
            var folder = drive.appendingPathComponent(value.dropFirst(3).replacingOccurrences(of: "\\", with: "/"))
            if [".exe", ".dll"].contains(where: value.lowercased().hasSuffix) { folder.deleteLastPathComponent() }
            return !fm.fileExists(atPath: folder.appendingPathComponent("steam.exe").path)
        }
        var pending: [(URL, Data)] = []
        for (file, machine) in [("system.reg", true), ("user.reg", false)] {
            let url = prefix.appendingPathComponent(file)
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw SteamRuntimeFiles.Failure.conflict
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            pending.append((url, Data(try SteamRuntimeFiles.registry(text, machine: machine, stale: stale).utf8)))
        }
        for name in files {
            let target = try SteamRuntimeFiles.destination(SteamRuntimeFiles.relativeRoot + "/" + name, under: drive)
            if fm.fileExists(atPath: target.path), !fm.contentsEqual(atPath: target.path, andPath: stage.appendingPathComponent(name).path) {
                SteamRuntimeFiles.lastConflict = name
                throw SteamRuntimeFiles.Failure.conflict
            }
        }
        try Task.checkCancellation()
        // No suspension during commit. steam.exe is last, so a check for an installed
        // client never mistakes a partial package for one. A retry accepts
        // identical files left by an interrupted commit, never replaces others.
        for (url, bytes) in pending {
            let backup = url.appendingPathExtension("dock-setup-bak")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
            try bytes.write(to: url, options: .atomic)
        }
        for name in files.sorted(by: { $0 == "steam.exe" ? false : ($1 == "steam.exe" ? true : $0 < $1) }) {
            let target = try SteamRuntimeFiles.destination(SteamRuntimeFiles.relativeRoot + "/" + name, under: drive)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage.appendingPathComponent(name), to: target)
        }
        await progress("Steam components are ready.")
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif



enum DockError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// A Steam game installed in the client's library, as Dock needs it.
struct DockGame: Equatable, Sendable {
    let id: Int
    let installDir: String
    let library: String
    let customExecutables: Bool

    var windowsInstallPath: String {
        "C:\\" + (library + "/common/" + installDir).replacingOccurrences(of: "/", with: "\\")
    }
}

enum MadeiraDock {
    static let enabledKey = "steam.launchThroughDock"

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "dockhost", withExtension: "exe", subdirectory: "arm64ec-windows")
    }
    static var bundled: Bool { bundledURL != nil }

    static var prefix: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VirtualRoot", isDirectory: true)
    }
    static var drive: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    static var clientRoot: URL { drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true) }
    static var clientInstalled: Bool {
        FileManager.default.fileExists(atPath: clientRoot.appendingPathComponent("steamclient64.dll").path)
    }
    /// steamclient64.dll is the build the Dock host verifies.
    static var clientSupported: Bool {
        guard let data = try? Data(contentsOf: clientRoot.appendingPathComponent("steamclient64.dll"), options: .mappedIfSafe) else {
            return false
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == SteamRuntimeFiles.clientSHA256
    }

    static func validAppID(_ value: Int) -> Bool { value > 0 && UInt64(value) < UInt64(UInt32.max) }

    /// The Dock description of a game iDeck installed, from its install record.
    static func game(appID: UInt32) -> DockGame? {
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        let record = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: record), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let folder = state["installdir"]?.string,
              folder == SteamInstallFiles.safeFolderName(folder),
              (state["StateFlags"]?.string.flatMap { UInt32($0) } ?? 0) & 4 != 0 else { return nil }
        return DockGame(id: Int(appID), installDir: folder, library: SteamInstallPaths.libraryRelative,
                        customExecutables: state["CheckGuid"]?.fields?.isEmpty == false)
    }

    /// Copies the bundled host to C:\windows\system32\dockhost.exe when it changed.
    static func stageHost() throws -> URL {
        guard let source = bundledURL else {
            throw DockError.message("Madeira Dock is not built into this IPA.")
        }
        let target = drive.appendingPathComponent("windows/system32/dockhost.exe")
        let fm = FileManager.default
        if !fm.contentsEqual(atPath: source.path, andPath: target.path) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }
        return target
    }

    // MARK: Sign-in transfer

    /// Tokens stay in Keychain except for this bounded one-use transfer. The
    /// payload is not an ownership claim: Valve authenticates it in the guest.
    static func envelope(account: String, token: String, steamID: UInt64, appID: Int) throws -> Data {
        let name = Array(account.utf8), secret = Array(token.utf8)
        guard (1...64).contains(name.count), (1...8192).contains(secret.count),
              name.allSatisfy({ (33...126).contains($0) }),
              secret.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              steamID >> 56 == 1, (steamID >> 52) & 15 == 1, (steamID >> 32) & 0xfffff == 1,
              steamID & 0xffffffff != 0, validAppID(appID) else {
            throw DockError.message("Your Steam sign-in cannot be handed to Dock. Sign in to Steam again in iDeck.")
        }
        var data = Data("MDOCK001".utf8)
        func append(_ value: UInt64, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        append(steamID, bytes: 8); append(UInt64(appID), bytes: 4)
        append(UInt64(name.count), bytes: 2); append(UInt64(secret.count), bytes: 2)
        data.append(contentsOf: name); data.append(contentsOf: secret)
        return data
    }

    /// The JWT subject selects the account; it is deliberately not treated as
    /// authenticated identity. Only Valve accepting the token can establish it.
    static func subject(_ token: String) throws -> UInt64 {
        guard token.utf8.count <= 8192 else { throw DockError.message("Steam sign-in is too large.") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw DockError.message("Steam sign-in needs renewal.") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["sub"] as? String, let id = UInt64(text) else {
            throw DockError.message("Steam sign-in needs renewal.")
        }
        return id
    }

    /// The seeded prefix has C: but no guaranteed Z: mapping. Wine's Unix
    /// namespace reaches the protected native file without a drive mapping
    /// and without moving the transfer into the user-visible Documents folder.
    static func handoffGuestPath(_ url: URL, unixNamespace: Bool = true) -> String {
        (unixNamespace ? "\\\\?\\unix" : "Z:") + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: Report

    /// The host's report: a bounded set of numeric fields, never arbitrary guest text.
    struct Report {
        var fields: [String: String] = [:]
        var result: Int? { fields["probe-result"].flatMap(Int.init) }
        var failure: String? {
            guard let result, result != 0 else { return nil }
            if result == 30 {
                if fields["session-unsupported-client"] == "1" || fields["session-user-method-mismatch"] != nil {
                    return "Madeira Dock does not support this Steam client build. Dock only drives client builds it has verified; the log has the client fingerprint and the failed check."
                }
                return "Madeira Dock could not initialize the Steam session (code 30). Export the log to identify the failed check."
            }
            // The host waits 90 s after sign-in for Valve's client to count the game
            // among the account's subscriptions (madeira-dock src/session.c).
            if result == 34 {
                return fields["session-authenticated-online"] == "1"
                    ? "Steam signed in but did not confirm this game's license in time. Export the log before trying again."
                    : "Steam did not finish signing in. Check the connection and try again."
            }
            if result == 54, fields["launch-user-arguments-invalid"] != nil {
                return "The game's launch arguments are invalid or too long. Edit them in Game details and try again."
            }
            if result == 35 { return "Steam did not confirm a license for this game on the signed-in account." }
            // Offline start (madeira-dock docs/OFFLINE.md): Valve's client decides.
            if result == 50 {
                return fields["session-offline-abi"] == "0"
                    ? "There is no connection, and this Steam client build cannot be started offline by Madeira Dock. Connect to the internet and try again."
                    : "There is no connection, and Steam has nothing saved to sign this account in offline. Start a game once while online; Steam then allows offline starts until its offline sign-in expires."
            }
            if result == 51 { return "There is no connection, and Steam refused to sign in offline. Connect to the internet and start the game once. Export the log if it happens again." }
            if result == 52 { return "Steam signed in offline, but what it has saved does not list this game. Start this game once while online, then it can be played offline." }
            if result == 37 {
                if fields["session-native-handoff-app-mismatch"] == "1" {
                    return "Madeira Dock received a sign-in transfer for a different launch. Close the session and try again."
                }
                return "Madeira Dock could not read the one-use Steam sign-in transfer. Steam has not checked the login yet. Export the log before trying again."
            }
            // Valve's client could not prepare the game's per-user executable.
            if result == 49 {
                switch fields["ceg-result"].flatMap(Int.init) {
                case -1: return "Steam took too long to prepare this game's executable. Check the connection and try again."
                case 0: return "Steam did not start preparing this game's executable. Verify the game's files with Steam, then try again."
                case 10: return "Steam is busy with this game (updating or running). Try again in a moment."
                case -4: return "Steam's Windows service manager could not be started, so Steam could not prepare this game's executable."
                case -5: return "Steam's Windows service is not installed in Madeira's Windows setup, so Steam could not prepare this game's executable."
                default: return "Steam could not prepare this game's executable for your account (code \(fields["ceg-result"] ?? "?"))."
                }
            }
            if result == 45 || result == 48, fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
                return "Steam rejected this game's launch option. Refresh the Steam library and try again."
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               (22...23).contains(error), fields["launch-config-wait"] != nil {
                return "Steam did not finish loading this game's configuration after signing in. Wait a minute and start the game again."
            }
            // The host asked again for up to three minutes while Steam still counted
            // another session of this account as playing (refusal 35); it still did.
            if result == 45 || result == 48, fields["launch-client-error"] == "35", fields["launch-session-wait"] != nil {
                return "Steam still says this account is playing in another session. Close the game on your other device (or wait a few minutes after a closed session) and start it again."
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               let reason = Self.launchRefusal(error, waited: result == 48) {
                return reason
            }
            return "Madeira Dock could not complete the Steam launch (code \(result)). Export the log before trying again."
        }

        /// Valve's own launch refusal (EAppUpdateError) in words. Numbers only
        /// come from the host report; nothing here changes what Steam decided.
        static func launchRefusal(_ error: Int, waited: Bool) -> String? {
            switch error {
            case 5: return "Steam did not confirm a license for this game on the signed-in account."
            case 6, 21: return "Steam could not reach its servers to start this game. Check the connection and try again."
            case 16: return "Steam reports this game is already running. Close it, then try again."
            case 17, 19, 20:
                return waited
                    ? "Steam could not finish installing content this game needs. Try again later."
                    : "Steam needs to install or update content this game depends on before it can start. Start the game again to let Madeira Dock wait for Steam."
            case 18: return "Steam does not see this game as installed."
            case 28: return "Steam could not find the game's executable."
            // Steam's CreateProcess for the game failed: Madeira could not load the program.
            case 29: return "Steam started this game's program, but Madeira could not load it (Steam reports an invalid platform). Export the log: it names the reason."
            case 22, 23, 24: return "Steam could not read this game's configuration. Try again."
            case 25: return "Steam says this game is not released yet."
            case 26: return "Steam says this game is not available in your region."
            case 35: return "Steam says this account is playing in another session. Close the game on your other device and start it again."
            default: return nil
            }
        }
    }

    static let reportAllowed: Set<String> = ["probe-start-bits", "client-machine", "client-pe-timestamp",
        "load-client-begin", "load-client-error", "public-client021-present", "engine005-present",
        "engine-factory-result", "session-client-adapter", "session-unsupported-client", "session-user-method-mismatch",
        "session-private-abi-verified", "session-login-disabled", "session-native-handoff-invalid",
        "session-native-handoff-app-mismatch", "session-handoff-stage", "session-handoff-error",
        "session-account-input-invalid", "session-app-input-invalid",
        "session-native-token-submitted", "session-logon-start-result", "session-connection-result",
        "session-authenticated-online", "session-requested-app-entitled", "session-subscription-count",
        "session-requested-app-listed", "session-auth-test-result",
        "session-online-subscription-count", "session-online-app-zero-query", "session-online-callback-id",
        "session-timeout-subscription-count", "session-timeout-app-listed", "session-timeout-still-online",
        "session-online-blip", "session-online-blips", "session-online-lost", "session-entitlement-source",
        "session-offline-abi", "session-offline-requested", "session-offline-can", "session-offline-logon-result",
        "session-offline-logon-retry", "session-offline-logon-state", "session-offline-callback-id",
        "session-offline-entitled", "session-offline-listed", "session-offline-timeout-state",
        "session-offline-fallback", "session-offline-ready",
        "launch-user-arguments-bytes", "launch-user-arguments-invalid",
        "launch-client-error", "launch-option-index", "launch-option-invalid", "launch-option-missing",
        "launch-update-wait", "launch-update-retry", "launch-update-ready",
        "launch-config-wait", "launch-config-gave-up", "launch-session-wait", "launch-session-gave-up",
        "ceg-request", "ceg-request-result", "ceg-request-busy", "ceg-server-result", "ceg-job-result",
        "ceg-finished-jobs", "ceg-result", "ceg-disabled", "ceg-unsupported-client",
        "ceg-scm", "ceg-scm-started", "ceg-scm-error", "ceg-service-registered", "ceg-service-install", "ceg-service-stop", "ceg-scm-stopped",
        "game-scm", "game-scm-timeout", "launch-keep-alive",
        "shutdown-begin", "shutdown-complete", "probe-result"]
    /// The host's report rounds (madeira-dock src/main.c).
    static let reportRounds: Set<String> = ["ml1820", "ml1830", "ml1860", "ml1870", "ml1970", "ml1990", "ml2000", "ml2011", "ml2015", "ml2016"]

    static func parseReport(_ data: Data) -> Report {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return Report() }
        var report = Report()
        // Ignore a partial final line until the writer completes and flushes it.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "[steam-host]", reportRounds.contains(String(parts[1])) else { continue }
            let field = parts[2].trimmingCharacters(in: .newlines).split(separator: "=", maxSplits: 1)
            guard field.count == 2 else { continue }
            let key = String(field[0]), value = String(field[1])
            if key == "client-sha256", value.utf8.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                report.fields[key] = value
            } else if key == "session-callback-id", let number = Int32(value) {
                // Valve's callback IDs after sign-in (the host reports the first 16), in
                // order, as one field: the poll logs a field only when it changes.
                let ids = report.fields["session-callback-ids"]
                if (ids?.split(separator: ",").count ?? 0) < 16 {
                    report.fields["session-callback-ids"] = (ids.map { $0 + "," } ?? "") + String(number)
                }
            } else if reportAllowed.contains(key), let number = Int32(value) {
                report.fields[key] = String(number)
            }
        }
        return report
    }

    @MainActor private static var lastReport = Report()

    /// Reads C:\madeira-dock.txt and logs fields that changed ([dock-report]).
    @MainActor static func pollReport() -> Report {
        let url = drive.appendingPathComponent("madeira-dock.txt")
        guard let file = try? FileHandle(forReadingFrom: url) else { return lastReport }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 32769), data.count <= 32768 else { return lastReport }
        let report = parseReport(data)
        for key in report.fields.keys.sorted() where report.fields[key] != lastReport.fields[key] {
            SteamLog.event("[dock-report] \(key)=\(report.fields[key]!)")
        }
        // The host ended: its whole report, in order, so the sequence and repeats of
        // its numeric fields are in the diagnostic log (each line is `[steam-host]
        // <round> <field>=<number>`; nothing else is in the file).
        if report.fields["probe-result"] != nil, lastReport.fields["probe-result"] == nil {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("[steam-host] ") }
            SteamLog.event("[dock-report-file] lines=\(lines.count)")
            for line in lines.prefix(400) { SteamLog.event("[dock-report-file] " + line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        lastReport = report
        return report
    }

    // MARK: Launch

    private static var transferURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iDeckDock", isDirectory: true).appendingPathComponent("launch.auth")
    }

    /// Removes an unconsumed transfer (session end, sign-out, app start).
    @MainActor static func cleanup() {
        if let url = transferURL { try? FileManager.default.removeItem(at: url) }
        unsetenv("MADEIRA_DOCK_AUTH_FILE")
        unsetenv("MADEIRA_DOCK_OFFLINE")
    }

    /// Writes the one-use transfer to protected Application Support storage
    /// (complete file protection, mode 0600, excluded from backups, created
    /// exclusively) and puts only its guest path in the environment. No
    /// token, account name or path is logged.
    @MainActor static func writeHandoff(account: String, token: String, appID: Int) throws {
        cleanup()
        lastReport = Report()
        let report = drive.appendingPathComponent("madeira-dock.txt")
        if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.removeItem(at: report) }
        guard let url = transferURL else { throw DockError.message("Dock's private transfer folder is unavailable.") }
        var data = try envelope(account: account, token: token, steamID: subject(token), appID: appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let fm = FileManager.default
        var folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DockError.message("Dock's transfer folder is invalid.")
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DockError.message("iDeck could not create Dock's private sign-in transfer.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            try file.write(contentsOf: data); try file.close()
            setenv("MADEIRA_DOCK_AUTH_FILE", handoffGuestPath(url), 1)
            SteamLog.event("[dock-handoff] protected-file-ready=1")
        } catch { try? file.close(); cleanup(); throw error }
    }

    /// The host's environment for one launch.
    static func configure(_ game: DockGame, launchOption: UInt32 = 0, arguments: String = "") {
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"] {
            setenv(key, "1", 1)
        }
        setenv("MADEIRA_STEAM_HOST_APPID", String(game.id), 1)
        setenv("MADEIRA_STEAM_HOST_LAUNCH_OPTION", String(launchOption), 1)
        setenv("MADEIRA_STEAM_HOST_CLIENT_DIR", SteamRuntimeFiles.windowsRoot, 1)
        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", game.windowsInstallPath, 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\madeira-dock.txt", 1)
        // The client receives only this game's extra arguments, separately from the host's
        // explorer/cmd command. An empty profile clears any previous game's choice.
        if arguments.isEmpty { unsetenv("MADEIRA_STEAM_HOST_ARGUMENTS") }
        else { setenv("MADEIRA_STEAM_HOST_ARGUMENTS", arguments, 1) }
        // The install record lists per-user executables: Dock asks Valve's client to prepare
        // them before it launches. env.MADEIRA_DOCK_CEG = 0 never asks.
        if game.customExecutables && true {
            setenv("MADEIRA_STEAM_HOST_CEG", "1", 1)
        } else {
            unsetenv("MADEIRA_STEAM_HOST_CEG")
        }
        // Never let a stale environment choose the PC cached-account test path.
        unsetenv("MADEIRA_STEAM_HOST_ACCOUNT"); unsetenv("MADEIRA_STEAM_HOST_STEAMID")
        // Valve's client unloads DLLs while it starts and the loader can map a different
        // DLL of the same size at the same address. The engine's opt-in image-retire
        // switch (MADEIRA_JIT_IMAGE_RETIRE, off for every other session) gives that DLL
        // fresh code instead of the unloaded one's translation. Dock sessions turn it on;
        // an engine without the switch ignores the variable. env.MADEIRA_DOCK_IMAGE_RETIRE = 0
        // leaves it off, and an explicit env.MADEIRA_JIT_IMAGE_RETIRE in madeira.cfg still wins.
        let retire = true
        if retire { setenv("MADEIRA_JIT_IMAGE_RETIRE", "1", 1) }
        SteamLog.event("[dock-launch] image-retire=\(retire ? 1 : 0)")
        // While the loader loads Valve's client and its many imports, the emulator's
        // image-map handler can commit a page of its own heap under its interval lock; the
        // commit's notification then waits for that same lock and the host parks for good
        // (no report after load-client-begin). Wine's opt-in MADEIRA_IMAGE_MAP_GUARD (off for
        // every other session) keeps the emulator's own memory calls un-notified there, as
        // on the syscall path. Dock sessions turn it on; ntdll without the switch ignores it.
        // env.MADEIRA_DOCK_IMAGE_MAP_GUARD = 0 leaves it off.
        let guardMap = true
        if guardMap { setenv("MADEIRA_IMAGE_MAP_GUARD", "1", 1) }
        SteamLog.event("[dock-launch] image-map-guard=\(guardMap ? 1 : 0)")
        DockOffline.configure(appID: game.id)
    }

    /// Sets everything for one launch: the host, the sign-in transfer and its
    /// environment. Returns the program to start (dockhost.exe).
    @MainActor static func prepareLaunch(appID: UInt32, arguments: String) throws -> URL {
        guard bundled else { throw DockError.message("Madeira Dock is not built into this IPA.") }
        guard clientInstalled else {
            throw DockError.message("Steam's client components are missing. Download them in Settings › Steam.")
        }
        guard let game = game(appID: appID) else {
            throw DockError.message("Steam does not list this game as fully installed.")
        }
        guard let credentials = SteamSignIn.credentialsForDock() else {
            throw DockError.message("Sign in to Steam to start games through Steam.")
        }
        let host = try stageHost()
        try writeHandoff(account: credentials.accountName, token: credentials.refreshToken, appID: game.id)
        configure(game, arguments: arguments)
        SteamLog.event("[dock-launch] app=\(appID)")
        return host
    }
}

/// Offline play for Steam games started through Madeira Dock.
///
/// Valve's client can log an account on without a connection, with an offline
/// logon ticket Steam issues to it during an online logon (desktop Steam's
/// Offline Mode). The host asks the client for exactly that (madeira-dock
/// docs/OFFLINE.md): Madeira decides nothing about ownership and stores no
/// ticket. What lives here is only what the app needs around it:
///
/// - whether the device has a network path, so a start without one asks for the
///   offline logon straight away (`MADEIRA_DOCK_OFFLINE=1`) instead of waiting
///   out a connection that cannot happen;
/// - a note of the last online start in which Valve's client confirmed a licence
///   and said the account can log on offline (the host's
///   `session-offline-ready=1`), for the Game details mark. Steam's offline
///   sign-in belongs to the ACCOUNT: with it, Valve's client answers the licence
///   question for any game from the list it cached, whether or not that game was
///   ever started online. So the note is one date for the account, plus the games
///   started online since, which matters only for a game whose per-user
///   executable Steam prepares on its first start (that needs a connection). It
///   is a display aid: an offline start is always decided by Valve's client.
///
/// `env.MADEIRA_DOCK_OFFLINE_LOGON = 0` removes the feature in the app and in
/// the host (which reads the same variable).
enum DockOffline {
    static let enabled = true

    private static let monitor = NWPathMonitor()
    private static var started = false
    /// Starts the path monitor. Called at app start, so the path is current by
    /// the time anything is launched.
    static func begin() {
        guard enabled, !started else { return }
        started = true
        monitor.start(queue: DispatchQueue(label: "ideck.dock-offline.path"))
    }
    /// No usable network path right now. False until the monitor has started.
    static var networkDown: Bool { started && monitor.currentPath.status != .satisfied }

    private static let key = "madeiraDockOfflineVerified", accountKey = "madeiraDockOfflineAccount"
    /// When Valve's client last reported, in an online start, that it can log this
    /// account on offline; nil if it never has on this installation.
    static var accountSaved: Date? {
        guard enabled else { return nil }
        var t = UserDefaults.standard.double(forKey: accountKey)
        // A build that kept only the per-game dates: the newest of those is the account's.
        if t <= 0, let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
            t = all.values.max() ?? 0
        }
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// When this game last started online in such a session; nil if it never has.
    static func verified(_ appID: Int) -> Date? {
        guard enabled, let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let t = all[String(appID)] else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    /// What Game details says about a game the Dock starts.
    enum Mark: Equatable {
        case ready(Date)        // Steam can sign in offline; this game needs nothing more
        case needsFirstStart    // Steam can sign in offline, but prepares this game's program online first
        case needsOnline        // Steam has no offline sign-in saved yet
    }
    /// `preparedOnline`: the game's install record lists per-user executables,
    /// which Valve's client prepares on the first start, over the network.
    static func mark(_ appID: Int, preparedOnline: Bool) -> Mark {
        guard let saved = accountSaved else { return .needsOnline }
        if preparedOnline, verified(appID) == nil { return .needsFirstStart }
        return .ready(saved)
    }
    private static func save(_ appID: Int) {
        let now = Date().timeIntervalSince1970
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        all[String(appID)] = now
        UserDefaults.standard.set(all, forKey: key)
        UserDefaults.standard.set(now, forKey: accountKey)
    }
    /// Sign-in removed or changed: the notes belonged to that account.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    /// The app the running Dock session was started for.
    private(set) static var sessionApp: Int?
    private static var sessionMarked = false

    /// Part of MadeiraDock.configure: tells the host when there is no network.
    static func configure(appID: Int) {
        sessionApp = appID
        sessionMarked = false
        let offline = enabled && networkDown
        if offline { setenv("MADEIRA_DOCK_OFFLINE", "1", 1) } else { unsetenv("MADEIRA_DOCK_OFFLINE") }
        SteamLog.event("[dock-offline] enabled=\(enabled ? 1 : 0) network=\(networkDown ? "down" : "up") request=\(offline ? 1 : 0) account-saved=\(accountSaved != nil ? 1 : 0) game-started-online=\(verified(appID) != nil ? 1 : 0)")
    }

    /// Follows the host's report (MadeiraDockModel.watchReport): an online start
    /// in which Valve's client confirmed the licence and reported that it can log
    /// the account on offline saves the game for offline play.
    @MainActor static func observe(_ fields: [String: String]) {
        guard enabled, !sessionMarked, let app = sessionApp,
              fields["session-offline-requested"] == nil,
              fields["session-requested-app-listed"] == "1",
              fields["session-offline-ready"] == "1" else { return }
        sessionMarked = true
        save(app)
        SteamLog.event("[dock-offline] Valve's client can log this account on offline: saved")
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static let changed = Notification.Name("MadeiraDockOfflineChanged")
}
