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
    var artworkFilename: String? = nil
    var updatedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, title, arguments, resolution, graphicsAPI, metalFXEnabled, fpsLimit, avxEnabled, artworkFilename, updatedAt
    }

    init(id: String, title: String, arguments: String = "", resolution: String = "1280x720", graphicsAPI: String = "Automatic", metalFXEnabled: Bool = false, fpsLimit: String = "60", avxEnabled: Bool = false, artworkFilename: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.arguments = arguments
        self.resolution = resolution
        self.graphicsAPI = graphicsAPI
        self.metalFXEnabled = metalFXEnabled
        self.fpsLimit = fpsLimit
        self.avxEnabled = avxEnabled
        self.artworkFilename = artworkFilename
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        arguments = try values.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        resolution = try values.decodeIfPresent(String.self, forKey: .resolution) ?? "1280x720"
        graphicsAPI = try values.decodeIfPresent(String.self, forKey: .graphicsAPI) ?? "Automatic"
        metalFXEnabled = try values.decodeIfPresent(Bool.self, forKey: .metalFXEnabled) ?? false
        fpsLimit = try values.decodeIfPresent(String.self, forKey: .fpsLimit) ?? "60"
        avxEnabled = try values.decodeIfPresent(Bool.self, forKey: .avxEnabled) ?? false
        artworkFilename = try values.decodeIfPresent(String.self, forKey: .artworkFilename)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
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

    func artworkURL(for profile: WindowsGameProfile) -> URL? {
        guard let filename = profile.artworkFilename,
              filename.range(of: #"^[A-Za-z0-9._-]{1,120}$"#, options: .regularExpression) != nil else {
            return nil
        }
        let url = artworkDirectory.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func setArtwork(from source: URL, for profileID: String) throws -> String {
        let hasScope = source.startAccessingSecurityScopedResource()
        defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic"].contains(ext) else {
            throw WindowsLibraryError.unsupportedArtwork
        }
        try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let safeID = String(Data(profileID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "").prefix(80))
        let filename = safeID + "." + ext
        let destination = artworkDirectory.appendingPathComponent(filename)
        let temporary = artworkDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        return filename
    }

    private var artworkDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck/GameArt", isDirectory: true)
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
        let id = profileID(for: target)
        if let artworkFilename = profiles[id]?.artworkFilename {
            let artwork = artworkDirectory.appendingPathComponent(artworkFilename).standardizedFileURL
            if artwork.deletingLastPathComponent() == artworkDirectory.standardizedFileURL {
                try? fileManager.removeItem(at: artwork)
            }
        }
        try fileManager.removeItem(at: target)
        profiles.removeValue(forKey: id)
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
    case unsupportedArtwork

    var errorDescription: String? {
        switch self {
        case .unsupportedExecutable:
            return "Choose a Windows .exe file."
        case .unsafePath:
            return "iDeck refused to remove a file outside its Windows library."
        case .unsupportedArtwork:
            return "Choose a PNG, JPG, JPEG or HEIC image for the cover."
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
