import CryptoKit
import Foundation

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

    /// The program a session of one-time installs runs: Wine's cmd.exe, staged
    /// from the bundle into system32 (the launch checks a real PE file there).
    /// nil when this build has none: the installs are then skipped.
    static func stageCommandShell() -> URL? {
        let target = drive.appendingPathComponent("windows/system32/cmd.exe")
        let fm = FileManager.default
        let linked = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if !linked, fm.fileExists(atPath: target.path) { return target }
        guard let source = ["arm64ec-windows", "x86_64-windows", "aarch64-windows"]
            .map({ Bundle.main.bundleURL.appendingPathComponent($0 + "/cmd.exe") })
            .first(where: { fm.fileExists(atPath: $0.path) }) else { return nil }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if linked { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// No cmd.exe to run a game's one-time installs: they are recorded as run
    /// (Visual C++ is built in; DirectX and the rest come with Wine) and the
    /// game starts.
    static func skipInstalls(_ game: DockGame) -> Int {
        let runs = DockInstallers.found(game, drive: drive).processes.map(\.run)
        guard !runs.isEmpty else { return 0 }
        return (try? SteamInstallScripts.mark(runs, prefix: prefix)) ?? 0
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
