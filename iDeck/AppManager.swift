import Foundation
import UniformTypeIdentifiers

enum IPAInstallError: LocalizedError {
    case invalidArchive
    case unsupportedArchive
    case unsafeArchivePath
    case missingPayload
    case missingAppBundle
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The selected file is not a readable IPA/ZIP archive."
        case .unsupportedArchive: return "This IPA uses a ZIP feature that the current extractor does not support (for example ZIP64 or encryption)."
        case .unsafeArchivePath: return "The IPA contains an unsafe file path and was rejected."
        case .missingPayload: return "The archive does not contain a top-level Payload directory."
        case .missingAppBundle: return "The Payload directory does not contain a valid .app bundle with Info.plist."
        case .copyFailed(let reason): return "Could not copy the app bundle: \(reason)"
        }
    }
}

class AppManager: ObservableObject {
    @Published var installedApps: [URL] = []
    @Published private(set) var artworkRevision = 0
    private let fileManager = FileManager.default
    private var appsDirectory: URL { fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("GuestApps", isDirectory: true) }

    init() {
        try? fileManager.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        refreshInstalledApps()
    }

    func refreshInstalledApps() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: appsDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            installedApps = contents.filter { url in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.pathExtension == "app" }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch { installedApps = [] }
    }

    func displayName(for appURL: URL) -> String {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return appURL.deletingPathExtension().lastPathComponent
        }
        return (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    func bundleIdentifier(for appURL: URL) -> String? {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    func iconURL(for appURL: URL) -> URL? {
        if let custom = customArtworkURL(for: appURL) {
            return custom
        }
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return nil
        }
        let bundleIcons = info["CFBundleIcons"] as? [String: Any]
        let primaryIcon = bundleIcons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconNames = primaryIcon?["CFBundleIconFiles"] as? [String] ?? []
        for name in iconNames.reversed() {
            let candidates = [
                appURL.appendingPathComponent(name + ".png"),
                appURL.appendingPathComponent(name)
            ]
            if let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
                return found
            }
        }
        return nil
    }

    func customArtworkURL(for appURL: URL) -> URL? {
        let filename = artworkFilename(for: appURL)
        let url = artworkDirectory.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func setArtwork(from source: URL, for appURL: URL) throws {
        let hasScope = source.startAccessingSecurityScopedResource()
        defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic"].contains(ext) else {
            throw IPAInstallError.copyFailed("Choose a PNG, JPG, JPEG or HEIC image.")
        }
        try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let destination = artworkDirectory.appendingPathComponent(artworkFilename(for: appURL))
        let temporary = artworkDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        artworkRevision &+= 1
    }

    private func artworkFilename(for appURL: URL) -> String {
        let key = bundleIdentifier(for: appURL) ?? appURL.lastPathComponent
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return String(encoded.prefix(96)) + ".art"
    }

    private var artworkDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck/GuestAppsArtwork", isDirectory: true)
    }

    func uninstallApp(at url: URL) throws {
        let appsRoot = appsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = url.standardizedFileURL
        guard target.pathExtension == "app",
              target.deletingLastPathComponent().resolvingSymlinksInPath() == appsRoot,
              target.resolvingSymlinksInPath().deletingLastPathComponent() == appsRoot else {
            throw IPAInstallError.copyFailed("Refused to remove an app outside iDeck's app library.")
        }
        try fileManager.removeItem(at: target)
        refreshInstalledApps()
    }

    func installIPA(from url: URL, completion: @escaping (Result<URL, IPAInstallError>) -> Void) {
        let hasScope = url.startAccessingSecurityScopedResource()
        let fileManager = self.fileManager
        let appsDirectory = self.appsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            let workDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let extractPath = workDirectory.appendingPathComponent("Extracted", isDirectory: true)
            let stagedArchive = workDirectory.appendingPathComponent("Source.ipa")
            defer { try? fileManager.removeItem(at: workDirectory) }
            let result: Result<URL, IPAInstallError>
            do {
                guard fileManager.fileExists(atPath: url.path), url.pathExtension.lowercased() == "ipa" else { throw IPAInstallError.invalidArchive }
                try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: url, to: stagedArchive)
                try ZipExtractor.extract(archive: stagedArchive, to: extractPath)
                let payloadPath = extractPath.appendingPathComponent("Payload", isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: payloadPath.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw IPAInstallError.missingPayload }
                let contents = try fileManager.contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: [.isDirectoryKey])
                guard let appBundle = contents.first(where: { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }), fileManager.fileExists(atPath: appBundle.appendingPathComponent("Info.plist").path) else { throw IPAInstallError.missingAppBundle }
                let destination = appsDirectory.appendingPathComponent(appBundle.lastPathComponent, isDirectory: true)
                do {
                    if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                    try fileManager.moveItem(at: appBundle, to: destination)
                } catch { throw IPAInstallError.copyFailed(error.localizedDescription) }
                result = .success(destination)
            } catch let error as IPAInstallError { result = .failure(error) }
            catch ZipError.unsupported { result = .failure(.unsupportedArchive) }
            catch ZipError.unsafePath { result = .failure(.unsafeArchivePath) }
            catch ZipError.invalidArchive { result = .failure(.invalidArchive) }
            catch { result = .failure(.copyFailed(error.localizedDescription)) }
            DispatchQueue.main.async {
                if case .success = result { self?.refreshInstalledApps() }
                completion(result)
            }
        }
    }
}
