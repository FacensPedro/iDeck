// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Where Madeira's own Steam downloads live, and how one is read and removed
// (docs/STEAM_LIBRARY.md). Foundation only, so tests/host/check-steam-library.py
// compiles this file as it is.
//
// A download goes into Madeira Dock's own Steam library folder,
// C:\Program Files (x86)\Steam\steamapps, as `common/<installdir>` plus Steam's
// `appmanifest_<appid>.acf` install record. That is exactly the layout
// Madeira Dock's discovery (MadeiraDock.games) reads and Valve's client, which
// Dock starts the game through, understands: a game is "installed" for Dock
// once its record says so, and the record is written last.

/// Conservative, offline compatibility hint based only on Steam PICS launch
/// options and filenames already installed in the same game folder.
enum SteamLaunchCompatibility {
    enum Kind: String { case direct, launcherChild, steamClient, antiCheat }

    struct Finding {
        let kind: Kind
        let warning: String?
    }

    static func classify(executable: String, launchType: String = "",
                         localEntries: [String] = []) -> Finding {
        let name = executable.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map { String($0).lowercased() } ?? ""
        let files = Set(localEntries.prefix(1024).map { $0.lowercased() })
        let antiCheatFiles: Set<String> = [
            "easyanticheat", "easyanticheat_eos", "easyanticheat_eos_setup.exe",
            "easyanticheat.exe", "beservice.exe", "battleye",
            "bedaisy.sys", "vgk.sys", "eac_launcher.exe", "eaanticheat.gameservicelauncher.exe"
        ]
        if antiCheatFiles.contains(name) || !files.isDisjoint(with: antiCheatFiles) {
            return Finding(kind: .antiCheat,
                           warning: "Known kernel anti-cheat components are not supported by Wine on iOS.")
        }
        let kind = launchType.lowercased()
        if kind.contains("launcher") || name.contains("launcher") {
            return Finding(kind: .launcherChild,
                           warning: "This Steam launcher may start another game process. Enable child processes only if needed.")
        }
        if name == "steam.exe" || files.contains("steamclient.dll") {
            return Finding(kind: .steamClient,
                           warning: "This game may require the Windows Steam client or Steam DRM.")
        }
        return Finding(kind: .direct, warning: nil)
    }
}

enum SteamInstallPaths {
    /// The library folder, relative to drive_c (the value `DockGame.library` has).
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"

    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(libraryRelative, isDirectory: true) }
    static func common(drive: URL) -> URL { steamApps(drive: drive).appendingPathComponent("common", isDirectory: true) }

    /// Whether an install (its drive-relative library folder) is in the library
    /// Madeira downloads into, and so can be updated or removed here.
    static func isManaged(library: String) -> Bool {
        library.caseInsensitiveCompare(libraryRelative) == .orderedSame
    }
}

enum SteamInstallFiles {
    /// The `buildid` the install record of an app states, or nil when there is
    /// no readable record.
    static func buildID(appID: Int, steamApps: URL) -> Int? {
        guard let state = record(appID: appID, steamApps: steamApps) else { return nil }
        return state["buildid"]?.string.flatMap { Int($0) }
    }

    static func installDirectoryName(appID: Int, steamApps: URL) -> String? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let name = state["installdir"]?.string,
              !name.isEmpty, name == safeFolderName(name) else { return nil }
        return name
    }

    /// The install size the record states (`SizeOnDisk`, bytes), or nil.
    static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let size = state["SizeOnDisk"]?.string.flatMap({ Int64($0) }), size > 0 else { return nil }
        return size
    }

    /// Actual logical game-file size. Steam manifests and CDN compressed
    /// chunk totals are estimates, not a measurement of installed files.
    /// Only traverse the game's own directory: never count symlink targets,
    /// external folders, journals or Steam app manifests.
    nonisolated static func logicalInstalledSize(at folder: URL) -> UInt64? {
        let fm = FileManager.default
        var root = stat()
        guard lstat(folder.path, &root) == 0,
              (root.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return nil }
        // Explicit directory traversal avoids platform differences in
        // DirectoryEnumerator's handling of directory symlinks. Never visit
        // a target reached through a symbolic link.
        var directories = [folder]
        var bytes: UInt64 = 0
        while let current = directories.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: current.path) else {
                return nil
            }
            for name in names {
                let entry = current.appendingPathComponent(name)
                var item = stat()
                guard lstat(entry.path, &item) == 0 else { return nil }
                let type = item.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFDIR) {
                    directories.append(entry)
                } else if type == mode_t(S_IFREG) {
                    guard item.st_size >= 0 else { return nil }
                    let (sum, overflow) = bytes.addingReportingOverflow(UInt64(item.st_size))
                    if overflow { return nil }
                    bytes = sum
                }
                // Symbolic links and all special file types are omitted.
            }
        }
        return bytes
    }

    /// Removes an app's install: its folder under `common`, its record, its
    /// resume journal and the records of the apps that own its shared depots
    /// (those describe the same folder). Only paths strictly inside
    /// `steamApps/common` are removed.
    nonisolated static func delete(appID: Int, folderName: String, steamApps: URL) {
        let fm = FileManager.default
        _ = ExternalDrives.removeExternalInstall(at: steamApps.appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(safeFolderName(folderName), isDirectory: true))
        let common = steamApps.appendingPathComponent("common", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let folder = common.appendingPathComponent(safeFolderName(folderName)).resolvingSymlinksInPath().standardizedFileURL
        if folder.path.hasPrefix(common.path + "/"), folder.deletingLastPathComponent().path == common.path {
            try? fm.removeItem(at: folder)
        }
        let recordURL = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        if let state = record(appID: appID, steamApps: steamApps) {
            let shared = (state["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }).prefix(64)
            for (_, owner) in shared {
                guard let ownerID = owner.string.flatMap({ Int($0) }), ownerID > 0, ownerID != appID,
                      let ownerState = record(appID: ownerID, steamApps: steamApps),
                      let dir = ownerState["installdir"]?.string
                else { continue }
                // An owner in another folder (its own installdir) goes too when
                // it holds nothing but depots shared into this app.
                let mine = Set(shared.filter { $0.value.string == owner.string }.map { $0.key })
                let held = Set((ownerState["InstalledDepots"]?.fields ?? [:]).keys)
                guard safeFolderName(dir).caseInsensitiveCompare(safeFolderName(folderName)) == .orderedSame ||
                      held.isSubset(of: mine) else { continue }
                try? fm.removeItem(at: steamApps.appendingPathComponent("appmanifest_\(ownerID).acf"))
            }
        }
        try? fm.removeItem(at: recordURL)
        try? fm.removeItem(at: steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
        try? fm.removeItem(at: steamApps.appendingPathComponent(".ideck-dlc/\(appID)", isDirectory: true))
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Resolves Steam's Windows launch metadata against the installed files.
    /// Valve's paths may have different casing than the extracted APFS tree.
    /// Check an exact match first and only enumerate a directory on mismatch.
    /// Ambiguous case-insensitive matches and symbolic links are refused.
    nonisolated static func resolveLaunchPath(_ relative: String, root: URL,
                                              executable: Bool) -> URL? {
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        let raw = relative.replacingOccurrences(of: "\\", with: "/")
        var cleaned = raw
        while cleaned.hasPrefix("./") { cleaned.removeFirst(2) }
        if !executable && (cleaned.isEmpty || cleaned == ".") { return rootURL }

        var folded: [String: String] = [:]
        guard let safe = safeRelativePath(cleaned, folded: &folded),
              safe.utf8.count < 1024,
              !safe.isEmpty,
              (!executable || safe.lowercased().hasSuffix(".exe")) else { return nil }

        let components = safe.split(separator: "/").map(String.init)
        guard components.count <= 32 else { return nil }
        let manager = FileManager.default
        var current = rootURL
        for (index, component) in components.enumerated() {
            let exact = current.appendingPathComponent(component)
            let name: String
            if (try? exact.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey,
                                                      .isSymbolicLinkKey])) != nil {
                name = component
            } else {
                guard let contents = try? manager.contentsOfDirectory(atPath: current.path) else {
                    return nil
                }
                let matches = contents.filter {
                    $0.caseInsensitiveCompare(component) == .orderedSame
                }
                guard matches.count == 1 else { return nil }
                name = matches[0]
            }
            let candidate = current.appendingPathComponent(name)
            guard let attributes = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  attributes.isSymbolicLink != true else { return nil }
            let isLast = index == components.count - 1
            if !isLast || !executable {
                guard attributes.isDirectory == true else { return nil }
            } else {
                guard attributes.isRegularFile == true else { return nil }
            }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootURL.path + "/") else { return nil }
            current = resolved
        }
        return current
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    /// The `AppState` block of `appmanifest_<appid>.acf` when the file is
    /// readable, bounded, and names this app.
    private static func record(appID: Int, steamApps: URL) -> SteamValue? {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state
    }
}


enum SteamDLCRecords {
    private struct Record: Codable {
        let parentID: UInt32
        let dlcID: UInt32
        let files: [String]
    }

    private static func directory(parentID: UInt32, steamApps: URL) -> URL {
        steamApps.appendingPathComponent(".ideck-dlc", isDirectory: true)
            .appendingPathComponent(String(parentID), isDirectory: true)
    }

    private static func url(parentID: UInt32, dlcID: UInt32, steamApps: URL) -> URL {
        directory(parentID: parentID, steamApps: steamApps)
            .appendingPathComponent("\(dlcID).json")
    }

    static func isInstalled(parentID: UInt32, dlcID: UInt32, steamApps: URL) -> Bool {
        load(parentID: parentID, dlcID: dlcID, steamApps: steamApps) != nil
    }

    private static func load(parentID: UInt32, dlcID: UInt32, steamApps: URL) -> Record? {
        let file = url(parentID: parentID, dlcID: dlcID, steamApps: steamApps)
        guard let data = try? Data(contentsOf: file), data.count <= 4 * 1024 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.parentID == parentID, record.dlcID == dlcID,
              record.files.count <= 100_000 else { return nil }
        return record
    }

    static func markInstalled(parentID: UInt32, dlcID: UInt32, files: [String], steamApps: URL) throws {
        let directory = directory(parentID: parentID, steamApps: steamApps)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = load(parentID: parentID, dlcID: dlcID, steamApps: steamApps)?.files ?? []
        let normalized = Array(Set(previous + files)).sorted()
        guard normalized.count <= 100_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        let record = Record(parentID: parentID, dlcID: dlcID, files: normalized)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url(parentID: parentID, dlcID: dlcID, steamApps: steamApps),
                       options: .atomic)
    }

    static func uninstall(parentID: UInt32, dlcID: UInt32, steamApps: URL) -> Bool {
        guard let record = load(parentID: parentID, dlcID: dlcID, steamApps: steamApps) else {
            return false
        }
        let folder = directory(parentID: parentID, steamApps: steamApps)
        let otherIDs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .compactMap { name -> UInt32? in
                guard name.hasSuffix(".json") else { return nil }
                return UInt32(String(name.dropLast(5)))
            }
            .filter { $0 != dlcID }
        var shared = Set<String>()
        for id in otherIDs {
            if let other = load(parentID: parentID, dlcID: id, steamApps: steamApps) {
                shared.formUnion(other.files)
            }
        }

        let common = steamApps.appendingPathComponent("common", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        for entry in record.files where !shared.contains(entry) {
            var folded: [String: String] = [:]
            guard let relative = SteamInstallFiles.safeRelativePath(entry, folded: &folded),
                  !relative.isEmpty, relative == entry else { continue }
            let target = common.appendingPathComponent(relative).standardizedFileURL
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(common.path + "/"),
                  target.path.hasPrefix(common.path + "/") else { continue }
            try? FileManager.default.removeItem(at: target)
        }
        do {
            try FileManager.default.removeItem(at: url(parentID: parentID, dlcID: dlcID, steamApps: steamApps))
            return true
        } catch {
            return false
        }
    }
}
