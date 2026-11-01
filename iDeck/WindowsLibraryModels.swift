import Foundation
import Combine
import UIKit
import ImageIO

struct WindowsGameProfile: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var arguments: String = ""
    var resolution: String = "960x540"
    var surfaceScaling: String = "fit"
    /// Always "Automatic": Direct3D 11 and 12 are chosen per game at launch
    /// (WindowsEnvironment.prepareGraphicsAPI). Kept so saved profiles load.
    var graphicsAPI: String = "Automatic"

    /// Profiles from before the automatic choice may hold another value.
    static func normalizedGraphicsAPI(_ stored: String?) -> String { "Automatic" }
    var controllerAPI: String = "Automatic"
    /// "Automatic" (on when the x64 executable references vulkan-1.dll), "On" or "Off".
    var vulkanMode: String = "Automatic"
    /// "Automatic" (desktop OpenGL through Zink when bundled), "Desktop OpenGL" or "OpenGL ES".
    var openGLBackend: String = "Automatic"
    /// Direct3D 12 renderer: "Madeira D3D12" (Metal, default) or "VKD3D-Proton"
    /// (vkd3d-proton on Vulkan/MoltenVK, Madeira's `d3d12 = vkd3d`; x64 only).
    var d3d12Renderer: String = "Madeira D3D12"
    static let d3d12Renderers = ["Madeira D3D12", "VKD3D-Proton"]
    var touchControlPreset: String = "xbox"
    var metalFXEnabled: Bool = false
    var fpsLimit: String = "60"
    var avxEnabled: Bool = false
    var keepChildProcessesRunning: Bool = false
    /// Writes the recommended config lines of a recognised game at launch.
    var useRecommended: Bool = true
    /// Steam games: start through Valve's Windows client (Madeira Dock).
    var launchThroughSteam: Bool = false
    /// FEX code-change checks: "Automatic" (full for Unity/Mono games),
    /// "Fast" (page tracking) or "Compatible" (full, slower).
    var codeChecks: String = "Automatic"
    static let codeCheckModes = ["Automatic", "Fast", "Compatible"]
    var artworkFilename: String? = nil
    var updatedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, title, arguments, resolution, surfaceScaling, graphicsAPI, controllerAPI, touchControlPreset, metalFXEnabled, fpsLimit, avxEnabled, keepChildProcessesRunning, artworkFilename, updatedAt, vulkanMode, openGLBackend, useRecommended, launchThroughSteam, codeChecks, d3d12Renderer
    }

    static let vulkanModes = ["Automatic", "On", "Off"]
    static let openGLBackends = ["Automatic", "Desktop OpenGL", "OpenGL ES"]

    init(id: String, title: String, arguments: String = "", resolution: String = "960x540", surfaceScaling: String = "fit", graphicsAPI: String = "Automatic", controllerAPI: String = "Automatic", touchControlPreset: String = "xbox", metalFXEnabled: Bool = false, fpsLimit: String = "60", avxEnabled: Bool = false, keepChildProcessesRunning: Bool = false, artworkFilename: String? = nil, updatedAt: Date = Date(), vulkanMode: String = "Automatic", openGLBackend: String = "Automatic") {
        self.id = id
        self.title = title
        self.arguments = arguments
        self.resolution = resolution
        self.surfaceScaling = ["fit", "fill", "stretch", "aspect"].contains(surfaceScaling) ? surfaceScaling : "fit"
        self.graphicsAPI = graphicsAPI
        self.controllerAPI = controllerAPI
        self.touchControlPreset = ["xbox", "minimal", "off"].contains(touchControlPreset) ? touchControlPreset : "xbox"
        self.metalFXEnabled = metalFXEnabled
        self.fpsLimit = fpsLimit
        self.avxEnabled = avxEnabled
        self.keepChildProcessesRunning = keepChildProcessesRunning
        self.artworkFilename = artworkFilename
        self.updatedAt = updatedAt
        self.vulkanMode = Self.vulkanModes.contains(vulkanMode) ? vulkanMode : "Automatic"
        self.openGLBackend = Self.openGLBackends.contains(openGLBackend) ? openGLBackend : "Automatic"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        arguments = try values.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        resolution = try values.decodeIfPresent(String.self, forKey: .resolution) ?? "960x540"
        surfaceScaling = {
            let saved = (try? values.decodeIfPresent(String.self, forKey: .surfaceScaling)) ?? "fit"
            return ["fit", "fill", "stretch", "aspect"].contains(saved) ? saved : "fit"
        }()
        graphicsAPI = Self.normalizedGraphicsAPI(try values.decodeIfPresent(String.self, forKey: .graphicsAPI))
        controllerAPI = try values.decodeIfPresent(String.self, forKey: .controllerAPI) ?? "Automatic"
        let savedTouchPreset = try values.decodeIfPresent(String.self, forKey: .touchControlPreset) ?? "xbox"
        touchControlPreset = ["xbox", "minimal", "off"].contains(savedTouchPreset) ? savedTouchPreset : "xbox"
        metalFXEnabled = try values.decodeIfPresent(Bool.self, forKey: .metalFXEnabled) ?? false
        fpsLimit = try values.decodeIfPresent(String.self, forKey: .fpsLimit) ?? "60"
        avxEnabled = try values.decodeIfPresent(Bool.self, forKey: .avxEnabled) ?? false
        keepChildProcessesRunning = try values.decodeIfPresent(Bool.self, forKey: .keepChildProcessesRunning) ?? false
        useRecommended = (try? values.decodeIfPresent(Bool.self, forKey: .useRecommended)) ?? true
        launchThroughSteam = (try? values.decodeIfPresent(Bool.self, forKey: .launchThroughSteam)) ?? false
        let savedChecks = (try? values.decodeIfPresent(String.self, forKey: .codeChecks)) ?? "Automatic"
        codeChecks = Self.codeCheckModes.contains(savedChecks) ? savedChecks : "Automatic"
        artworkFilename = try values.decodeIfPresent(String.self, forKey: .artworkFilename)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        let savedVulkan = (try? values.decodeIfPresent(String.self, forKey: .vulkanMode)) ?? "Automatic"
        vulkanMode = Self.vulkanModes.contains(savedVulkan) ? savedVulkan : "Automatic"
        let savedGL = (try? values.decodeIfPresent(String.self, forKey: .openGLBackend)) ?? "Automatic"
        openGLBackend = Self.openGLBackends.contains(savedGL) ? savedGL : "Automatic"
        let savedD3D12 = (try? values.decodeIfPresent(String.self, forKey: .d3d12Renderer)) ?? "Madeira D3D12"
        d3d12Renderer = Self.d3d12Renderers.contains(savedD3D12) ? savedD3D12 : "Madeira D3D12"
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

        let directory = prefixPath.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
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

    func importEmbeddedIcon(for executable: URL) async {
        let profileID = profileID(for: executable)
        let current = profile(for: profileID, title: executable.deletingPathExtension().lastPathComponent)
        guard artworkURL(for: current) == nil else { return }
        let data = await Task.detached(priority: .utility) {
            WindowsPEIcon.pngData(from: executable)
        }.value
        guard let data, !data.isEmpty, data.count <= 16 * 1024 * 1024 else { return }
        do {
            try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            let safeID = Data(profileID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            let name = String(safeID.prefix(80)) + "-extracted.png"
            try data.write(to: artworkDirectory.appendingPathComponent(name), options: .atomic)
            var profile = current
            profile.artworkFilename = name
            save(profile)
        } catch {
            NSLog("iDeck: unable to extract icon: %@", error.localizedDescription)
        }
    }

    func importExecutable(from source: URL, prefixPath: URL) throws -> URL {
        let hasScope = source.startAccessingSecurityScopedResource()
        defer { if hasScope { source.stopAccessingSecurityScopedResource() } }

        let fileExtension = source.pathExtension.lowercased()
        guard fileExtension == "exe" else {
            throw WindowsLibraryError.unsupportedExecutable
        }

        let directory = prefixPath.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
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
        let directory = prefixPath.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true).standardizedFileURL
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

enum WindowsPEIcon {
    static func pngData(from url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 128, size <= 1024 * 1024 * 1024,
              let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        func word(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - 2 else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func dword(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 |
                   Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard word(0) == 0x5A4D, let peOffset = dword(0x3C),
              peOffset >= 64, peOffset <= bytes.count - 256,
              dword(peOffset) == 0x00004550,
              let sectionCount = word(peOffset + 6), sectionCount > 0, sectionCount <= 96,
              let optionalSize = word(peOffset + 20),
              let optionalMagic = word(peOffset + 24),
              optionalMagic == 0x10B || optionalMagic == 0x20B else { return nil }

        let optional = peOffset + 24
        let dataDirectories = optional + (optionalMagic == 0x20B ? 112 : 96)
        guard optionalSize >= (optionalMagic == 0x20B ? 128 : 112),
              let resourceRVA = dword(dataDirectories + 16),
              resourceRVA > 0 else { return nil }

        struct Section {
            var rva: Int
            var rawSize: Int
            var rawOffset: Int
        }
        let sectionHeaders = optional + optionalSize
        var sections: [Section] = []
        for index in 0..<sectionCount {
            let offset = sectionHeaders + index * 40
            guard let rva = dword(offset + 12),
                  let rawSize = dword(offset + 16),
                  let rawOffset = dword(offset + 20),
                  rawOffset <= bytes.count,
                  rawSize <= bytes.count - rawOffset else { return nil }
            sections.append(Section(rva: rva, rawSize: rawSize, rawOffset: rawOffset))
        }
        func fileOffset(_ rva: Int, length: Int = 1) -> Int? {
            guard rva >= 0, length >= 0 else { return nil }
            for section in sections {
                guard rva >= section.rva else { continue }
                let relative = rva - section.rva
                guard relative <= section.rawSize, length <= section.rawSize - relative else { continue }
                return section.rawOffset + relative
            }
            return nil
        }
        guard fileOffset(resourceRVA, length: 16) != nil else { return nil }
        func relativeOffset(_ value: Int, length: Int = 1) -> Int? {
            guard value >= 0, value <= 32 * 1024 * 1024 else { return nil }
            return fileOffset(resourceRVA + value, length: length)
        }
        func directoryEntry(_ relative: Int, id: Int?) -> Int? {
            guard let base = relativeOffset(relative, length: 16),
                  let named = word(base + 12), let numbered = word(base + 14),
                  named + numbered <= 2048,
                  let entries = relativeOffset(relative + 16, length: (named + numbered) * 8)
            else { return nil }
            for index in 0..<(named + numbered) {
                let offset = entries + index * 8
                guard let name = dword(offset), let value = dword(offset + 4) else { continue }
                if id == nil || (name & 0x8000_0000 == 0 && name == id) {
                    return value
                }
            }
            return nil
        }
        func child(_ value: Int) -> Int? {
            guard value & 0x8000_0000 != 0 else { return nil }
            return value & 0x7FFF_FFFF
        }
        func resource(type: Int, id: Int?) -> Data? {
            guard let typeEntry = directoryEntry(0, id: type),
                  let typeDirectory = child(typeEntry),
                  let itemEntry = directoryEntry(typeDirectory, id: id),
                  let itemDirectory = child(itemEntry),
                  let languageEntry = directoryEntry(itemDirectory, id: nil),
                  languageEntry & 0x8000_0000 == 0,
                  let metadata = relativeOffset(languageEntry, length: 16),
                  let dataRVA = dword(metadata),
                  let size = dword(metadata + 4), size > 0, size <= 16 * 1024 * 1024,
                  let offset = fileOffset(dataRVA, length: size)
            else { return nil }
            return bytes.subdata(in: offset..<(offset + size))
        }

        guard let group = resource(type: 14, id: nil), group.count >= 20 else { return nil }
        func groupWord(_ offset: Int) -> Int {
            Int(group[offset]) | Int(group[offset + 1]) << 8
        }
        let count = groupWord(4)
        guard groupWord(2) == 1, count > 0, count <= 128,
              count <= (group.count - 6) / 14 else { return nil }
        let sorted = (0..<count).sorted { first, second in
            let a = 6 + first * 14, b = 6 + second * 14
            let dimensionA = (group[a] == 0 ? 256 : Int(group[a])) *
                             (group[a + 1] == 0 ? 256 : Int(group[a + 1]))
            let dimensionB = (group[b] == 0 ? 256 : Int(group[b])) *
                             (group[b + 1] == 0 ? 256 : Int(group[b + 1]))
            return dimensionA > dimensionB
        }

        func little16(_ value: Int) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }
        func little32(_ value: Int) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
             UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        }

        for index in sorted {
            let offset = 6 + index * 14
            let iconID = groupWord(offset + 12)
            guard let image = resource(type: 3, id: iconID), image.count <= 8 * 1024 * 1024 else { continue }
            let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
            if image.starts(with: pngSignature), let decoded = UIImage(data: image),
               let output = decoded.pngData() { return output }

            var ico = Data([0, 0, 1, 0, 1, 0])
            ico.append(contentsOf: [group[offset], group[offset + 1],
                                     group[offset + 2], group[offset + 3]])
            ico.append(contentsOf: little16(groupWord(offset + 4)))
            ico.append(contentsOf: little16(groupWord(offset + 6)))
            ico.append(contentsOf: little32(image.count))
            ico.append(contentsOf: little32(22))
            ico.append(image)
            if let source = CGImageSourceCreateWithData(ico as CFData, nil),
               let graphic = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return UIImage(cgImage: graphic).pngData()
            }
        }
        return nil
    }
}

struct SelectedEpicGame: Identifiable {
    let id: String
}
