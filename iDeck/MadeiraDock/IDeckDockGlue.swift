import CryptoKit
import Foundation

/// Repairs Steam's video-client FFmpeg dependencies and SDL3.dll from
/// compatible Windows x64 binaries supplied by the user from their own Steam
/// installation. Never use random DLL mirrors or overwrite a running client.
enum SteamDLLRepair {
    static let mediaLibraries = [
        "libavcodec-62.dll", "libavformat-62.dll", "libavutil-60.dll",
        "libavfilter-11.dll", "libswresample-6.dll", "libswscale-9.dll"
    ]
    static let videoLibrary = "video64.dll"
    static let sdlLibrary = "SDL3.dll"
    static let videoLibraries = mediaLibraries + [videoLibrary]
    static let clientLibraries = videoLibraries + [sdlLibrary]

    struct Report: Sendable {
        let copied: [String]
        let missing: [String]
        let invalid: [String]
    }

    static var sourceFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SteamDLLs", isDirectory: true)
    }

    static var hasImportFiles: Bool {
        guard let folder = sourceFolder else { return false }
        return clientLibraries.contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// The installed Steam client lacks a valid x64 video DLL or SDL3.dll.
    static func needsRepair(prefix: URL) -> Bool {
        let root = prefix.appendingPathComponent("drive_c")
            .appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steam.exe").path) else { return false }
        return clientLibraries.contains { !validX64DLL(root.appendingPathComponent($0)) }
    }

    /// Validates file type, PE32+ optional-header length, AMD64 machine and
    /// IMAGE_FILE_DLL, not merely MZ. It does not authenticate the publisher:
    /// use matching libraries from the user's own genuine Steam installation.
    static func validX64DLL(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, (4096...64 * 1024 * 1024).contains(count),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        let bytes = [UInt8](data)
        func u16(_ p: Int) -> UInt16 { UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> UInt32 { UInt32(u16(p)) | UInt32(u16(p + 2)) << 16 }
        guard bytes.count >= 0x40, bytes[0] == 0x4d, bytes[1] == 0x5a else { return false }
        let pe = Int(u32(0x3c))
        guard pe >= 0x40, pe + 26 <= bytes.count,
              u32(pe) == 0x00004550,
              u16(pe + 4) == 0x8664,
              u16(pe + 22) & 0x2000 != 0,
              u16(pe + 20) >= 112,
              u16(pe + 24) == 0x020b,
              pe + 24 + Int(u16(pe + 20)) <= count else { return false }
        return true
    }

    /// Install missing DLLs, and optionally replace a malformed existing
    /// SDL3.dll after keeping a backup. The FFmpeg family is all-or-nothing
    /// to avoid a partially installed, incompatible video64.dll chain.
    static func repair(prefix: URL) -> Report {
        let fm = FileManager.default
        let root = prefix.appendingPathComponent("drive_c")
            .appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true)
        guard fm.fileExists(atPath: root.appendingPathComponent("steam.exe").path),
              wine_process_is_running() == 0, wineserver_is_running() == 0,
              let folder = sourceFolder else {
            return Report(copied: [], missing: [], invalid: [])
        }
        let missingBefore = clientLibraries.filter { !validX64DLL(root.appendingPathComponent($0)) }
        guard hasImportFiles else {
            return Report(copied: [], missing: missingBefore, invalid: [])
        }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            return Report(copied: [], missing: missingBefore, invalid: ["unsafe import folder"])
        }
        let invalidSources = clientLibraries.filter { name in
            let input = folder.appendingPathComponent(name)
            return fm.fileExists(atPath: input.path) && !validX64DLL(input)
        }
        guard invalidSources.isEmpty else {
            return Report(copied: [], missing: missingBefore, invalid: invalidSources)
        }
        let invalidExisting = clientLibraries.filter { name in
            let target = root.appendingPathComponent(name)
            return fm.fileExists(atPath: target.path) && !validX64DLL(target)
        }
        // Unknown existing FFmpeg builds are preserved. SDL3.dll, however,
        // commonly exists with the wrong architecture: a verified x64 input
        // may replace that single file while keeping the original as backup.
        let blocked = invalidExisting.filter { $0 != sdlLibrary }
        guard blocked.isEmpty else {
            return Report(copied: [], missing: missingBefore, invalid: blocked)
        }
        let videoReady = videoLibraries.allSatisfy { name in
            validX64DLL(root.appendingPathComponent(name)) ||
            validX64DLL(folder.appendingPathComponent(name))
        }
        var copied: [String] = []
        var invalid: [String] = []
        let candidates = (videoReady ? videoLibraries : []) + [sdlLibrary]
        for name in candidates {
            let destination = root.appendingPathComponent(name)
            if validX64DLL(destination) { continue }
            let source = folder.appendingPathComponent(name)
            guard validX64DLL(source) else { continue }
            let exists = fm.fileExists(atPath: destination.path)
            if exists && name != sdlLibrary { continue }
            // Never follow a preexisting symlink, even for SDL3.dll.
            if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                invalid.append(name)
                continue
            }
            let backup = root.appendingPathComponent(name + ".ideck-invalid-backup")
            if exists && fm.fileExists(atPath: backup.path) {
                invalid.append(name)
                continue
            }
            do {
                // Stage the new file before changing anything in the Steam
                // client. On error, restore the exact original byte content.
                let temporary = root.appendingPathComponent(name + ".ideck-staging-" + UUID().uuidString)
                try fm.copyItem(at: source, to: temporary)
                defer { try? fm.removeItem(at: temporary) }
                guard validX64DLL(temporary) else { throw CocoaError(.fileReadCorruptFile) }
                if exists { try fm.moveItem(at: destination, to: backup) }
                do {
                    try fm.moveItem(at: temporary, to: destination)
                    copied.append(name)
                } catch {
                    if exists { try? fm.moveItem(at: backup, to: destination) }
                    throw error
                }
            } catch {
                AppLog.record("[steam-dll] could not repair \(name): \(error.localizedDescription)")
                invalid.append(name)
            }
        }
        if !videoReady && mediaLibraries.contains(where: { !validX64DLL(root.appendingPathComponent($0)) }) {
            AppLog.record("[steam-dll] incomplete FFmpeg set; refusing partial video64.dll dependency repair")
        }
        return Report(copied: copied,
                      missing: clientLibraries.filter { !validX64DLL(root.appendingPathComponent($0)) },
                      invalid: invalid)
    }
}

/// The last percentage shown for a download: a new one every 5 points.
final class SteamDownloadPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -5

    func next(_ percent: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let value = Swift.min(100, Swift.max(0, percent))
        guard value >= last + 5 || (value == 100 && last != 100) else { return nil }
        last = value
        return value
    }
}

/// Valve's official x64 video-client DLLs (FFmpeg family and SDL3.dll),
/// downloaded from Steam's update server and pinned by size and SHA-256.
enum SteamVideoLibraries {
    typealias Package = SteamRuntimeFiles.Package
    /// Valve's x64 video-client dependencies (win64 client manifest
    /// 1792618285): the FFmpeg family video64.dll imports and SDL3.dll.
    /// Only these DLLs are taken from the packages.
    static let packages = [
        Package(file: "bins_codecs_win64.zip.ad3f4b232ba00296ed683021adf1b761a629b74a", bytes: 13_241_033,
                sha256: "160c767800a310521a9926771c85a07ab4d71bd4b621d2d11c4dbbf63449447f"),
        Package(file: "bins_win64.zip.1f91da2609327de9658146b01307e89a13cc1ef8", bytes: 64_309_479,
                sha256: "f34b0d5924d0cca4c81775ed2fef0aee1ca060e2daa5c24270711267786c0236")
    ]

    /// Downloads Valve's pinned x64 video-client packages and places the
    /// FFmpeg DLLs and SDL3.dll in Documents/SteamDLLs, where
    /// SteamDLLRepair validates and installs them. Nothing is executed.
    static func fetch(progress: @Sendable (String) async -> Void) async throws {
        guard let folder = SteamDLLRepair.sourceFolder else { return }
        let fm = FileManager.default
        let names = SteamDLLRepair.mediaLibraries + [SteamDLLRepair.sdlLibrary]
        guard !names.allSatisfy({ SteamDLLRepair.validX64DLL(folder.appendingPathComponent($0)) }) else { return }
        let wanted = Set(names.map { $0.lowercased() })
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: SteamUpdateRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for (index, package) in packages.enumerated() {
            try Task.checkCancellation()
            await progress("Downloading Steam DLLs (\(index + 1) of \(packages.count))…")
            let url = URL(string: SteamRuntimeFiles.origin + package.file)!
            // iDeck: with real progress. The plain async download reported nothing until
            // a 64 MB package had finished, so the step looked stuck on a slow connection.
            let label = "Downloading Steam DLLs (\(index + 1) of \(packages.count))"
            let shown = SteamDownloadPercent()
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            let temporary: URL
            let http: HTTPURLResponse
            do {
                (temporary, http) = try await ObservedDownload.run(request, expected: Int64(package.bytes)) { written, total in
                    guard total > 0, let percent = shown.next(Int(written * 100 / total)) else { return }
                    Task { await progress("\(label) \(percent)%…") }
                }
            } catch let failure as ObservedDownload.Failure {
                throw failure.error
            }
            defer { try? fm.removeItem(at: temporary) }
            guard http.statusCode == 200,
                  http.url?.host == url.host, http.url?.scheme == "https",
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                throw SteamRuntimeFiles.Failure.invalidPackage
            }
            let archive = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard hash(archive) == package.sha256 else { throw SteamRuntimeFiles.Failure.invalidPackage }
            await progress("Verifying Steam DLLs…")
            try SteamRuntimeFiles.unpack(archive) { name, bytes in
                guard !name.contains("/"), wanted.contains(name.lowercased()) else { return }
                let target = folder.appendingPathComponent(name)
                guard !SteamDLLRepair.validX64DLL(target) else { return }
                try bytes.write(to: target, options: .atomic)
                guard SteamDLLRepair.validX64DLL(target) else {
                    try? fm.removeItem(at: target)
                    throw SteamRuntimeFiles.Failure.invalidPackage
                }
            }
        }
        await progress("Steam DLLs are ready.")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Redirects stay on Valve's update host (as SteamRuntime.swift's own delegate).
private final class SteamUpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "client-update.akamai.steamstatic.com"
            && (url?.port == nil || url?.port == 443) && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

// iDeck glue around Madeira Dock. MadeiraDock.swift, DockInstallers.swift,
// DockReset.swift, DockStartProgram.swift and SteamRuntime.swift in Vendor/Madeira
// are Madeira's (willfaust/Madeira, app/Madeira), copied verbatim. What follows
// is what iDeck needs around them: Madeira keeps these pieces in its library
// and ContentView, which iDeck does not have.

extension ExternalDrives {
    /// Madeira lists Steam libraries on external drives here; iDeck keeps its
    /// games in the prefix's own library.
    nonisolated static var steamLibraries: [String] { [] }
}

extension MadeiraDock {
    /// The installed Steam game Madeira Dock can start, by App ID.
    static func game(appID: UInt32) -> DockGame? {
        games(drive: drive).first { $0.id == Int(appID) }
    }

    /// iDeck's Wine prefix is Madeira's, Documents/wine (MadeiraDock.prefix).
    /// Earlier builds kept it in Documents/VirtualRoot, and one build linked
    /// Documents/wine to it; Madeira's Steam setup refuses linked folders
    /// ("Existing Steam files need attention"). The folder is moved, once,
    /// before anything uses it. A real Documents/wine is set aside, never deleted.
    static func linkPrefix() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let prefix = documents.appendingPathComponent("wine", isDirectory: true)
        let old = documents.appendingPathComponent("VirtualRoot", isDirectory: true)
        if (try? fm.destinationOfSymbolicLink(atPath: prefix.path)) != nil { try? fm.removeItem(at: prefix) }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? fm.destinationOfSymbolicLink(atPath: old.path)) == nil else { return }
        if fm.fileExists(atPath: prefix.path) {
            try? fm.moveItem(at: prefix, to: documents.appendingPathComponent("wine.old-\(Int(Date().timeIntervalSince1970))"))
        }
        do {
            try fm.moveItem(at: old, to: prefix)
            SteamLog.event("[prefix] moved Documents/VirtualRoot to Documents/wine")
        } catch {
            SteamLog.event("[prefix] could not move VirtualRoot: \(error.localizedDescription)")
        }
    }

    /// Marks the Visual C++ programs of a game's Steam install script as run
    /// when Visual C++ is built into iDeck (VisualCRuntimeBootstrap.installBundled).
    static func markBundledVisualCRuns(_ game: DockGame) {
        guard VisualCRuntimeBootstrap.bundled else { return }
        let runs = DockInstallers.found(game, drive: drive).processes
            .filter { process in
                let program = process.executable.lowercased()
                return program.contains("vcredist") || program.contains("vc_redist")
            }
            .map(\.run)
        guard !runs.isEmpty else { return }
        let marked = (try? SteamInstallScripts.mark(runs, prefix: prefix)) ?? 0
        SteamLog.event("[dock-installers] Visual C++ is built into iDeck: \(marked) Steam Visual C++ install(s) marked as run")
    }

    /// steamclient64.dll is the build the Dock host verifies.
    static var clientSupported: Bool {
        guard let data = try? Data(contentsOf: clientRoot.appendingPathComponent("steamclient64.dll"), options: .mappedIfSafe) else {
            return false
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == SteamRuntimeFiles.clientSHA256
    }

    /// Copies the bundled host to C:\windows\system32\dockhost.exe when it changed.
    static func stageHost() throws -> URL {
        let source = MadeiraRuntime.file("arm64ec-windows/dockhost.exe")
        guard FileManager.default.fileExists(atPath: source.path) else {
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

    /// The program a session of one-time installs runs: Wine's cmd.exe.
    /// Reject a truncated, linked or wrong-architecture interpreter before
    /// attempting Wine; never record prerequisites as completed on failure.
    private static func validCommandShell(_ url: URL) -> Bool {
        guard let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attrs.isRegularFile == true, attrs.isSymbolicLink != true else { return false }
        let machine = url.path.withCString { ideck_native_pe_machine($0) }
        return machine == 0x8664 || machine == 0xA641
    }

    static func stageCommandShell() -> URL? {
        let target = drive.appendingPathComponent("windows/system32/cmd.exe")
        let fm = FileManager.default
        let linked = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if !linked && fm.fileExists(atPath: target.path) {
            if validCommandShell(target) { return target }
            AppLog.record("[dock-installers] invalid Wine cmd.exe in prefix; restoring verified bundled interpreter")
        }
        // The seeded Wine prefix can have a cmd.exe symlink. Do not execute
        // its target; replace the link only after validating a bundled PE
        // interpreter, retaining the previous staging behavior.
        guard let source = ["arm64ec-windows", "x86_64-windows", "aarch64-windows"]
            .map({ MadeiraRuntime.file($0 + "/cmd.exe") })
            .first(where: validCommandShell) else {
            AppLog.record("[dock-installers] no valid x64/ARM64EC Wine cmd.exe in the IPA")
            return nil
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if linked || fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            guard validCommandShell(target) else {
                try? fm.removeItem(at: target)
                return nil
            }
            return target
        } catch {
            AppLog.record("[dock-installers] could not stage cmd.exe: \(error.localizedDescription)")
            return nil
        }
    }

}

/// The starting status line, from the host's report (Madeira's DockStartStatus
/// lives in its starting screen, which iDeck does not use).
enum IDeckDockStartStatus {
    static func text(_ fields: [String: String], waited: TimeInterval) -> String {
        if fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
            return "Steam rejected the game's launch option."
        }
        if fields["launch-update-wait"] != nil && fields["launch-update-ready"] == nil {
            return "Steam is installing required game content..."
        }
        if fields["launch-session-wait"] != nil && fields["launch-client-error"] == "35" {
            return "Waiting for Steam to release another game session..."
        }
        if fields["launch-config-wait"] != nil { return "Steam is loading the game's launch configuration..." }
        if fields["launch-client-error"] == "0" { return "Steam launched the game; waiting for graphics..." }
        if fields["ceg-request"] != nil && fields["ceg-result"] == nil { return "Steam is preparing the game's executable..." }
        if fields["session-offline-listed"] == "1" { return "Steam confirmed the game's offline license..." }
        if fields["session-offline-requested"] != nil || fields["session-offline-fallback"] != nil {
            return "Steam is attempting offline sign-in..."
        }
        if fields["session-requested-app-listed"] == "1" { return "Steam confirmed the game's license..." }
        if fields["session-authenticated-online"] == "1" { return "Steam signed in; checking the game license..." }
        if fields["session-native-token-submitted"] != nil || fields["session-logon-start-result"] != nil {
            return "Signing in to Steam..."
        }
        if fields["probe-start-bits"] != nil { return "Loading the Steam client..." }
        return waited >= 30 ? "Still initializing Madeira Dock..." : "Starting Madeira Dock..."
    }
}

extension Optional {
    /// The value, or `error` thrown.
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
