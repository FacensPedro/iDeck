import CryptoKit
import Foundation

/// Repairs Valve's Steam multimedia DLLs using files the device owner supplies
/// through Files > On My iPad > iDeck > SteamDLLs. Valve's binaries are never
/// redistributed, downloaded from third-party DLL sites, or synthesized.
/// No active Wine session is modified. An incompatible existing SDL3.dll is
/// backed up before replacement, with rollback if installation fails.
enum SteamDLLRepair {
    static let mediaLibraries = [
        "libavcodec-62.dll", "libavformat-62.dll", "libavutil-60.dll",
        "libavfilter-11.dll", "libswresample-6.dll", "libswscale-9.dll"
    ]
    static let videoLibrary = "video64.dll"
    static let sdlLibrary = "SDL3.dll"
    static let clientLibraries = mediaLibraries + [videoLibrary]

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
        return (clientLibraries + [sdlLibrary]).contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// PE structure and architecture checks are a safety gate, not a Valve
    /// signature check. A binary must come from the matching official Steam
    /// client. Do not import an arbitrary similarly named file.
    static func validDLL(_ url: URL, machine: UInt16) -> Bool {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, (4096...64 * 1024 * 1024).contains(count),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return false }
        let bytes = [UInt8](data)
        func u16(_ p: Int) -> UInt16 {
            UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
        }
        func u32(_ p: Int) -> UInt32 {
            UInt32(u16(p)) | UInt32(u16(p + 2)) << 16
        }
        guard bytes.count >= 0x40, bytes[0] == 0x4d, bytes[1] == 0x5a else { return false }
        let pe = Int(u32(0x3c))
        guard pe >= 0x40, pe + 26 <= bytes.count, u32(pe) == 0x00004550 else { return false }
        let optionalSize = Int(u16(pe + 20))
        let magic = machine == 0x014c ? UInt16(0x010b) : UInt16(0x020b)
        guard optionalSize >= (machine == 0x014c ? 96 : 112),
              pe + 24 + optionalSize <= count,
              pe + 24 + optionalSize <= bytes.count,
              u16(pe + 4) == machine,
              u16(pe + 24) == magic,
              u16(pe + 22) & 0x2000 != 0 else { return false }
        return true
    }

    static func validX64DLL(_ url: URL) -> Bool {
        validDLL(url, machine: 0x8664)
    }

    /// SDL3 is independent of video64/FFmpeg. Determine its architecture
    /// from Valve's installed Steam executable, rather than substituting an
    /// unrelated x64 DLL into a 32-bit client.
    static func steamClientMachine(root: URL) -> UInt16? {
        let exe = root.appendingPathComponent("steam.exe")
        let machine = exe.path.withCString { ideck_native_pe_machine($0) }
        return machine == 0x014c || machine == 0x8664 ? machine : nil
    }

    /// Move an incompatible SDL3.dll out of the search path and replace it
    /// only with the user's matching Steam copy. Preserve one deterministic
    /// backup and restore it if the copy or validation fails.
    private static func repairSDL3(root: URL, sourceFolder: URL, machine: UInt16)
        -> (copied: Bool, invalid: String?) {
        let fm = FileManager.default
        let target = root.appendingPathComponent(sdlLibrary)
        if validDLL(target, machine: machine) { return (false, nil) }
        let input = sourceFolder.appendingPathComponent(sdlLibrary)
        guard fm.fileExists(atPath: input.path) else { return (false, nil) }
        guard validDLL(input, machine: machine) else {
            return (false, "SDL3.dll import is not a matching Steam \(machine == 0x014c ? "x86" : "x64") DLL")
        }
        let exists = fm.fileExists(atPath: target.path)
        let backup = root.appendingPathComponent(sdlLibrary + ".ideck-incompatible-backup")
        if exists {
            guard (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                return (false, "SDL3.dll destination is a symlink")
            }
            guard !fm.fileExists(atPath: backup.path),
                  (try? backup.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
                return (false, "SDL3.dll backup already exists; manual review required")
            }
        }
        do {
            if exists { try fm.moveItem(at: target, to: backup) }
            do {
                try fm.copyItem(at: input, to: target)
                guard validDLL(target, machine: machine) else {
                    throw SteamRuntimeFiles.Failure.invalidPackage
                }
            } catch {
                try? fm.removeItem(at: target)
                if exists { try? fm.moveItem(at: backup, to: target) }
                throw error
            }
            if exists {
                AppLog.record("[steam-dll] replaced incompatible SDL3.dll; original preserved as SDL3.dll.ideck-incompatible-backup")
            }
            return (true, nil)
        } catch {
            return (false, "SDL3.dll repair failed: \(error.localizedDescription)")
        }
    }

    /// The video64 dependency group is all-or-nothing; SDL3 is independent.
    static func repair(prefix: URL) -> Report {
        let fm = FileManager.default
        let root = prefix.appendingPathComponent("drive_c")
            .appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true)
        guard fm.fileExists(atPath: root.appendingPathComponent("steam.exe").path) else {
            return Report(copied: [], missing: [], invalid: [])
        }
        guard wine_process_is_running() == 0 && wineserver_is_running() == 0 else {
            return Report(copied: [], missing: [], invalid: [])
        }
        guard let folder = sourceFolder else {
            return Report(copied: [], missing: [], invalid: [])
        }
        let machine = steamClientMachine(root: root)
        let sdlMissing = machine.map { !validDLL(root.appendingPathComponent(sdlLibrary), machine: $0) } ?? true
        let initialMissing = clientLibraries.filter { !validX64DLL(root.appendingPathComponent($0)) }
            + (sdlMissing ? [sdlLibrary] : [])
        guard let machine else {
            return Report(copied: [], missing: initialMissing, invalid: ["steam.exe PE architecture could not be verified"])
        }
        guard hasImportFiles else {
            return Report(copied: [], missing: initialMissing, invalid: [])
        }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            return Report(copied: [], missing: initialMissing, invalid: ["unsafe import folder"])
        }

        var copied: [String] = []
        var invalid: [String] = []
        let sdl = repairSDL3(root: root, sourceFolder: folder, machine: machine)
        if sdl.copied { copied.append(sdlLibrary) }
        if let reason = sdl.invalid { invalid.append(reason) }

        let invalidSources = clientLibraries.filter { name in
            let input = folder.appendingPathComponent(name)
            return fm.fileExists(atPath: input.path) && !validX64DLL(input)
        }
        invalid += invalidSources
        // Existing video64 and FFmpeg DLLs are not automatically overwritten.
        let invalidDestinations = clientLibraries.filter { name in
            let destination = root.appendingPathComponent(name)
            return fm.fileExists(atPath: destination.path) && !validX64DLL(destination)
        }
        invalid += invalidDestinations
        let prepared = clientLibraries.filter { name in
            validX64DLL(root.appendingPathComponent(name)) ||
                validX64DLL(folder.appendingPathComponent(name))
        }
        if invalidSources.isEmpty && invalidDestinations.isEmpty && prepared.count == clientLibraries.count {
            for name in clientLibraries {
                let destination = root.appendingPathComponent(name)
                if validX64DLL(destination) { continue }
                let source = folder.appendingPathComponent(name)
                guard validX64DLL(source), !fm.fileExists(atPath: destination.path) else { continue }
                do {
                    try fm.copyItem(at: source, to: destination)
                    copied.append(name)
                } catch {
                    AppLog.record("[steam-dll] could not copy \(name): \(error.localizedDescription)")
                }
            }
        }
        let finalMissing = clientLibraries.filter { !validX64DLL(root.appendingPathComponent($0)) }
            + (validDLL(root.appendingPathComponent(sdlLibrary), machine: machine) ? [] : [sdlLibrary])
        return Report(copied: copied, missing: finalMissing, invalid: invalid)
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
            guard validCommandShell(target) else {
                AppLog.record("[dock-installers] existing Wine cmd.exe is invalid or has an unsupported PE machine; no installers were marked complete")
                return nil
            }
            return target
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
            if linked { try fm.removeItem(at: target) }
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
