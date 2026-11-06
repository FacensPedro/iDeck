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

// iDeck glue around Madeira Dock. MadeiraDock.swift, DockInstallers.swift,
// DockReset.swift, DockStartProgram.swift and SteamRuntime.swift in this folder
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
        guard let source = Bundle.main.url(forResource: "dockhost", withExtension: "exe", subdirectory: "arm64ec-windows") else {
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
            .map({ Bundle.main.bundleURL.appendingPathComponent($0 + "/cmd.exe") })
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
