// External folders (USB or SSD drives) for game installs.
// Safety rules adapted from Madeira's ExternalStorage.swift and
// ExternalDrives.swift (GPL-3.0-or-later, Copyright 2026 David Brookes and
// 125hz, Madeira Converter Exception).
//
// iOS only lets the app reach a folder outside its sandbox through the folder
// picker. The picked URL is kept as a bookmark. Before Wine starts, each saved
// folder is opened again and linked into the prefix twice: as
// drive_c/External/<name>, so the executable browser works unchanged, and as
// dosdevices/<letter>:, so Windows lists it as a drive. Each writable folder
// holds a .ideck-library-id file, so a different drive mounted at the same
// place is never mistaken for the registered one. One folder can receive new
// Steam and GOG installs; a game installed there is linked into the prefix.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExternalStorageError: LocalizedError {
    case unsafePath, invalidRecord, mappingConflict, identityMismatch, unavailable, limitReached

    var errorDescription: String? {
        switch self {
        case .unsafePath: return tr("The requested path leaves the external folder.")
        case .invalidRecord: return tr("The saved external drive registration is invalid.")
        case .mappingConflict: return tr("The external drive mapping is already in use. Existing files were kept.")
        case .identityMismatch: return tr("This is not the registered folder. Select the original folder.")
        case .unavailable: return tr("The external drive is not available. Reconnect it and try again.")
        case .limitReached: return tr("No free Windows drive letter is left.")
        }
    }
}

struct ExternalFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var letter: String
    var bookmark: Data
    var receivesInstalls = false
    var libraryID: String?
}

enum ExternalStoragePath {
    /// Splits a relative path and rejects anything that could leave its root.
    static func components(_ relative: String) throws -> [String] {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, normalized.utf8.count < 4096,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") &&
                  !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else {
            throw ExternalStorageError.unsafePath
        }
        return parts
    }

    /// The URL of `relative` below `root`, refusing symbolic links on the way.
    static func native(_ relative: String, root: URL) throws -> URL {
        var candidate = root.resolvingSymlinksInPath().standardizedFileURL
        for part in try components(relative) {
            candidate.appendPathComponent(part)
            if let type = try? FileManager.default.attributesOfItem(atPath: candidate.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                throw ExternalStorageError.unsafePath
            }
        }
        return candidate
    }
}

enum ExternalStorageIdentity {
    static let marker = ".ideck-library-id"

    static func verify(_ id: String, root: URL) throws {
        let url = try ExternalStoragePath.native(marker, root: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 1024) <= 128,
              (try String(contentsOf: url, encoding: .utf8)) == id else {
            throw ExternalStorageError.identityMismatch
        }
    }

    /// Adopts an existing valid marker or writes a new one; never overwrites.
    static func register(root: URL) throws -> String {
        let url = try ExternalStoragePath.native(marker, root: root)
        if FileManager.default.fileExists(atPath: url.path) {
            let id = try String(contentsOf: url, encoding: .utf8)
            guard UUID(uuidString: id) != nil else { throw ExternalStorageError.invalidRecord }
            try verify(id, root: root)
            return id
        }
        let id = UUID().uuidString
        try Data(id.utf8).write(to: url, options: .withoutOverwriting)
        return id
    }
}

@MainActor
final class ExternalDrives: ObservableObject {
    static let shared = ExternalDrives()

    @Published private(set) var folders: [ExternalFolder] = []
    /// Folders opened this launch, with the path each resolved to.
    @Published private(set) var mounted: [UUID: URL] = [:]
    @Published var lastError: String?

    private static let letters = Array("defghijklmnopqrstuvwxy").map(String.init)
    private var loadFailed = false

    private static var store: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ideck-external.json")
    }

    private init() {
        do {
            let data = try Data(contentsOf: Self.store)
            guard data.count <= 4 << 20 else { throw ExternalStorageError.invalidRecord }
            let list = try JSONDecoder().decode([ExternalFolder].self, from: data)
            try Self.validate(list)
            folders = list
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        } catch {
            loadFailed = true
            AppLog.record("[external] saved registrations could not be read; files kept")
        }
    }

    private static func validate(_ list: [ExternalFolder]) throws {
        guard list.count <= letters.count,
              Set(list.map(\.id)).count == list.count,
              Set(list.map { $0.name.lowercased() }).count == list.count,
              Set(list.map(\.letter)).count == list.count,
              list.filter(\.receivesInstalls).count <= 1 else { throw ExternalStorageError.invalidRecord }
        for folder in list {
            guard try ExternalStoragePath.components(folder.name) == [folder.name],
                  letters.contains(folder.letter), !folder.bookmark.isEmpty, folder.bookmark.count <= 1 << 20,
                  folder.libraryID.map({ UUID(uuidString: $0) != nil }) ?? true else {
                throw ExternalStorageError.invalidRecord
            }
        }
    }

    private func save(_ list: [ExternalFolder]) throws {
        guard !loadFailed else { throw ExternalStorageError.invalidRecord }
        try Self.validate(list)
        try JSONEncoder().encode(list).write(to: Self.store, options: .atomic)
        folders = list
    }

    // MARK: Registration

    func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            guard folders.count < Self.letters.count,
                  let letter = Self.letters.first(where: { l in !folders.contains { $0.letter == l } }) else {
                throw ExternalStorageError.limitReached
            }
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
            let identity = readOnly ? nil : try ExternalStorageIdentity.register(root: url)
            var name = Self.safeName(url.lastPathComponent)
            var suffix = 2
            while folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                name = Self.safeName(url.lastPathComponent) + " \(suffix)"
                suffix += 1
            }
            try save(folders + [ExternalFolder(name: name, letter: letter, bookmark: bookmark, libraryID: identity)])
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    func remove(_ folder: ExternalFolder) {
        do {
            try save(folders.filter { $0.id != folder.id })
            if let root = mounted.removeValue(forKey: folder.id) { root.stopAccessingSecurityScopedResource() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setReceivesInstalls(_ folder: ExternalFolder, _ value: Bool) {
        var next = folders
        for index in next.indices {
            next[index].receivesInstalls = value && next[index].id == folder.id
        }
        do { try save(next); lastError = nil } catch { lastError = error.localizedDescription }
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { $0.value >= 32 && !"/\\:".unicodeScalars.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(48))
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "Drive" : trimmed
    }

    // MARK: Mounting

    /// Opens every saved folder and refreshes the prefix links. Run before
    /// Wine starts so Windows lists the drives.
    func mountAll(prefix: URL) {
        guard !loadFailed else { return }
        let fm = FileManager.default
        let linkRoot = prefix.appendingPathComponent("drive_c/External", isDirectory: true)
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try? fm.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        var next = folders
        for (index, folder) in folders.enumerated() {
            if mounted[folder.id] == nil {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil,
                                         bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource() else {
                    AppLog.record("[external] \(folder.letter): not connected")
                    continue
                }
                if let identity = folder.libraryID, (try? ExternalStorageIdentity.verify(identity, root: url)) == nil {
                    url.stopAccessingSecurityScopedResource()
                    AppLog.record("[external] \(folder.letter): identity mismatch; not mounted")
                    continue
                }
                if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    next[index].bookmark = fresh
                }
                mounted[folder.id] = url
            }
            guard let root = mounted[folder.id] else { continue }
            do {
                try Self.link(linkRoot.appendingPathComponent(folder.name), to: root)
                try Self.link(dosdevices.appendingPathComponent(folder.letter + ":"), to: root)
            } catch {
                AppLog.record("[external] \(folder.letter): \(error.localizedDescription)")
            }
        }
        if next != folders { try? save(next) }
    }

    /// Replaces a symbolic link atomically; never replaces a real file or folder.
    private static func link(_ link: URL, to root: URL) throws {
        let fm = FileManager.default
        if let type = try? fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
           type != .typeSymbolicLink {
            throw ExternalStorageError.mappingConflict
        }
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == root.path { return }
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".ideck-link-" + UUID().uuidString)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: root)
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, link.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: Installs

    /// The folder new games are installed into, when one is chosen and mounted.
    var installRoot: URL? {
        guard let folder = folders.first(where: \.receivesInstalls) else { return nil }
        return mounted[folder.id]
    }

    var installFolderMissing: String? {
        guard let folder = folders.first(where: \.receivesInstalls), mounted[folder.id] == nil else { return nil }
        return folder.name
    }

    /// Before a new install into `local` (a game folder inside the prefix):
    /// creates the game's folder on the chosen drive and links it into place.
    /// Returns false when the install stays on the device.
    @discardableResult
    func prepareExternalInstall(local: URL, store: String) -> Bool {
        guard let root = installRoot else { return false }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: local.path),
              (try? fm.attributesOfItem(atPath: local.path)) == nil else { return false }
        do {
            let target = try ExternalStoragePath.native("iDeck Games/\(store)/\(local.lastPathComponent)", root: root)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: local, withDestinationURL: target)
            AppLog.record("[external] \(store) install linked to external drive")
            return true
        } catch {
            AppLog.record("[external] install stays on device: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes a game folder that is a link to a registered drive: the files on
    /// the drive and the link. Returns false for anything else.
    nonisolated static func removeExternalInstall(at local: URL) -> Bool {
        let fm = FileManager.default
        guard let type = try? fm.attributesOfItem(atPath: local.path)[.type] as? FileAttributeType,
              type == .typeSymbolicLink,
              let destination = try? fm.destinationOfSymbolicLink(atPath: local.path) else { return false }
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        // Only folders iDeck created on a drive are removed.
        guard target.pathComponents.contains("iDeck Games"),
              target.lastPathComponent == local.lastPathComponent else { return false }
        try? fm.removeItem(at: target)
        try? fm.removeItem(at: local)
        return true
    }
}

struct ExternalDrivesSettingsView: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var isPickerPresented = false

    var body: some View {
        Form {
            Section {
                if drives.folders.isEmpty {
                    Text(tr("No external folders"))
                        .foregroundStyle(.secondary)
                }
                ForEach(drives.folders) { folder in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("\(folder.letter.uppercased()):  \(folder.name)", systemImage: "externaldrive")
                            Spacer()
                            Text(drives.mounted[folder.id] != nil ? tr("Connected") : tr("Not connected"))
                                .font(.caption)
                                .foregroundStyle(drives.mounted[folder.id] != nil ? .green : .secondary)
                        }
                        Toggle(tr("Install new games here"), isOn: Binding(
                            get: { folder.receivesInstalls },
                            set: { drives.setReceivesInstalls(folder, $0) }))
                            .font(.subheadline)
                    }
                    .swipeActions {
                        Button(tr("Remove"), role: .destructive) { drives.remove(folder) }
                    }
                }
                Button {
                    isPickerPresented = true
                } label: {
                    Label(tr("Add folder"), systemImage: "plus")
                }
            } footer: {
                Text(tr("Folders appear in Windows as drives and under C:\\External. Removing a folder here keeps its files."))
            }
            if let error = drives.lastError {
                Section {
                    Text(error).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(tr("External drives"))
        .fileImporter(isPresented: $isPickerPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { drives.add(url) }
        }
    }
}
