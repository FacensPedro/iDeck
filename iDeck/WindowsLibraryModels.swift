import Foundation
import Combine

struct WindowsGameProfile: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var arguments: String = ""
    var resolution: String = "1280x720"
    var graphicsAPI: String = "Automatic"
    var metalFXEnabled: Bool = false
    var fpsLimit: String = "60"
    var avxEnabled: Bool = false
    var updatedAt: Date = Date()
}

@MainActor
final class WindowsLibraryStore: ObservableObject {
    @Published private(set) var executableURLs: [URL] = []
    @Published private(set) var profiles: [String: WindowsGameProfile] = [:]

    private let fileManager = FileManager.default

    private var profileURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck-game-profiles.json")
    }

    init() {
        loadProfiles()
    }

    func refresh(prefixPath: URL?) {
        guard let prefixPath else {
            executableURLs = []
            return
        }

        let directory = prefixPath.appendingPathComponent("WindowsDownloads", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            executableURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            .filter { $0.pathExtension.lowercased() == "exe" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            executableURLs = []
        }
    }

    func profileID(for url: URL) -> String {
        "windows:" + url.lastPathComponent.lowercased()
    }

    func profile(for id: String, title: String) -> WindowsGameProfile {
        profiles[id] ?? WindowsGameProfile(id: id, title: title)
    }

    func save(_ profile: WindowsGameProfile) {
        var updated = profile
        updated.updatedAt = Date()
        profiles[updated.id] = updated
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: profileURL, options: .atomic)
        } catch {
            NSLog("iDeck: unable to save game profile: %@", error.localizedDescription)
        }
    }

    func importExecutable(from source: URL, prefixPath: URL) throws -> URL {
        let hasScope = source.startAccessingSecurityScopedResource()
        defer { if hasScope { source.stopAccessingSecurityScopedResource() } }

        let fileExtension = source.pathExtension.lowercased()
        guard fileExtension == "exe" else {
            throw WindowsLibraryError.unsupportedExecutable
        }

        let directory = prefixPath.appendingPathComponent("WindowsDownloads", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = source.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        var destination = directory.appendingPathComponent(safeName)
        if fileManager.fileExists(atPath: destination.path) {
            let name = destination.deletingPathExtension().lastPathComponent
            let suffix = UUID().uuidString.prefix(8)
            destination = directory.appendingPathComponent("\(name)-\(suffix).\(fileExtension)")
        }

        try fileManager.copyItem(at: source, to: destination)
        refresh(prefixPath: prefixPath)
        return destination
    }

    func uninstallExecutable(at url: URL, prefixPath: URL) throws {
        let directory = prefixPath.appendingPathComponent("WindowsDownloads", isDirectory: true).standardizedFileURL
        let target = url.standardizedFileURL
        guard target.deletingLastPathComponent() == directory,
              target.pathExtension.lowercased() == "exe",
              target.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw WindowsLibraryError.unsafePath
        }
        try fileManager.removeItem(at: target)
        profiles.removeValue(forKey: profileID(for: target))
        persistProfiles()
        refresh(prefixPath: prefixPath)
    }

    func removeProfile(for id: String) {
        profiles.removeValue(forKey: id)
        persistProfiles()
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profileURL),
              let decoded = try? JSONDecoder().decode([String: WindowsGameProfile].self, from: data) else {
            profiles = [:]
            return
        }
        profiles = decoded
    }

    private func persistProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: profileURL, options: .atomic)
        } catch {
            NSLog("iDeck: unable to save game profile: %@", error.localizedDescription)
        }
    }
}

enum WindowsLibraryError: LocalizedError {
    case unsupportedExecutable
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .unsupportedExecutable:
            return "Choose a Windows .exe file."
        case .unsafePath:
            return "iDeck refused to remove a file outside its Windows library."
        }
    }
}

struct SelectedLibraryURL: Identifiable {
    let url: URL
    var id: String { url.standardizedFileURL.path }
}

struct SelectedSteamGame: Identifiable {
    let game: SteamAppInfo
    var id: UInt32 { game.appID }
}
