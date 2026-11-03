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
        linkPrefix()
        return games(drive: drive).first { $0.id == Int(appID) }
    }

    /// Madeira's prefix is Documents/wine; iDeck's is Documents/VirtualRoot.
    /// Documents/wine is made a link to iDeck's prefix, so Madeira's code (kept
    /// verbatim) finds the games, the Steam client and the sign-in transfer there.
    static func linkPrefix() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let link = documents.appendingPathComponent("wine")
        let target = documents.appendingPathComponent("VirtualRoot", isDirectory: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing == target.path || existing == "VirtualRoot" { return }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            // A real folder from an earlier build: set aside, never deleted.
            try? fm.moveItem(at: link, to: documents.appendingPathComponent("wine.old-\(Int(Date().timeIntervalSince1970))"))
        }
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "VirtualRoot")
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
    static func stageCommandShell() throws -> URL {
        let target = drive.appendingPathComponent("windows/system32/cmd.exe")
        let fm = FileManager.default
        let linked = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        if linked || !fm.fileExists(atPath: target.path) {
            guard let source = ["arm64ec-windows", "x86_64-windows"]
                .map({ Bundle.main.bundleURL.appendingPathComponent($0 + "/cmd.exe") })
                .first(where: { fm.fileExists(atPath: $0.path) }) else {
                throw DockError.message("This build has no cmd.exe for Steam's one-time installs.")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if linked { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        }
        return target
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
