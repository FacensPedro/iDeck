import Foundation
import UniformTypeIdentifiers
import UIKit

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
    private let installQueue = DispatchQueue(label: "iDeck.ipa-install", qos: .userInitiated)
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

    func iconImage(for appURL: URL) -> UIImage? {
        if let iconURL = iconURL(for: appURL),
           let image = UIImage(contentsOfFile: iconURL.path) {
            return image
        }
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any],
              let bundle = Bundle(url: appURL) else { return nil }
        for iconKey in ["CFBundleIcons~ipad", "CFBundleIcons"] {
            guard let icons = info[iconKey] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            let names = ([primary["CFBundleIconName"] as? String].compactMap { $0 }) +
                (primary["CFBundleIconFiles"] as? [String] ?? [])
            for name in names.reversed() {
                if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                    return image
                }
            }
        }
        for name in ["AppIcon", "AppIcon60x60", "AppIcon76x76", "Icon"] {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
        }
        return nil
    }

    static func sizeOfInstalledApp(at appURL: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  properties.isRegularFile == true else { continue }
            total += Int64(properties.fileSize ?? 0)
        }
        return total
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
        let basename = artworkBasename(for: appURL)
        for ext in ["png", "jpg", "jpeg", "heic"] {
            let url = artworkDirectory.appendingPathComponent(basename + "." + ext)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func setArtwork(from source: URL, for appURL: URL) throws {
        let hasScope = source.startAccessingSecurityScopedResource()
        defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "heic"].contains(ext) else {
            throw IPAInstallError.copyFailed("Choose a PNG, JPG, JPEG or HEIC image.")
        }
        try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let basename = artworkBasename(for: appURL)
        for existingExt in ["png", "jpg", "jpeg", "heic"] {
            let old = artworkDirectory.appendingPathComponent(basename + "." + existingExt)
            if fileManager.fileExists(atPath: old.path) { try fileManager.removeItem(at: old) }
        }
        let destination = artworkDirectory.appendingPathComponent(basename + "." + ext)
        let temporary = artworkDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.moveItem(at: temporary, to: destination)
        artworkRevision &+= 1
    }

    private func artworkBasename(for appURL: URL) -> String {
        let key = bundleIdentifier(for: appURL) ?? appURL.lastPathComponent
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return String(encoded.prefix(96))
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
        let artwork = customArtworkURL(for: target)
        try fileManager.removeItem(at: target)
        if let artwork { try? fileManager.removeItem(at: artwork) }
        artworkRevision &+= 1
        refreshInstalledApps()
    }

    func installIPA(from url: URL, completion: @escaping (Result<URL, IPAInstallError>) -> Void) {
        let hasScope = url.startAccessingSecurityScopedResource()
        let appsDirectory = self.appsDirectory
        installQueue.async { [weak self] in
            let fileManager = FileManager.default
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            let workDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let extractPath = workDirectory.appendingPathComponent("Extracted", isDirectory: true)
            defer { try? fileManager.removeItem(at: workDirectory) }
            let result: Result<URL, IPAInstallError>
            do {
                guard fileManager.fileExists(atPath: url.path),
                      ["ipa", "zip"].contains(url.pathExtension.lowercased()) else {
                    throw IPAInstallError.invalidArchive
                }
                try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                try ZipExtractor.extract(archive: url, to: extractPath)
                let payloadPath = extractPath.appendingPathComponent("Payload", isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: payloadPath.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw IPAInstallError.missingPayload }
                let contents = try fileManager.contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: [.isDirectoryKey])
                let bundles = contents.filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                guard bundles.count == 1, let appBundle = bundles.first,
                      let info = NSDictionary(contentsOf: appBundle.appendingPathComponent("Info.plist")) as? [String: Any],
                      let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty, bundleID.utf8.count <= 255,
                      let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
                      executable != ".", executable != "..", !executable.contains("/"), !executable.contains("\\"),
                      fileManager.fileExists(atPath: appBundle.appendingPathComponent(executable).path) else {
                    throw IPAInstallError.missingAppBundle
                }
                if let minimum = info["MinimumOSVersion"] as? String {
                    let current = ProcessInfo.processInfo.operatingSystemVersion
                    let currentVersion = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
                    if minimum.compare(currentVersion, options: .numeric) == .orderedDescending {
                        throw IPAInstallError.copyFailed("Requires iOS " + minimum)
                    }
                }
                let installed = try fileManager.contentsOfDirectory(at: appsDirectory, includingPropertiesForKeys: nil)
                let existing = installed.first { candidate in
                    guard candidate.pathExtension == "app",
                          let old = NSDictionary(contentsOf: candidate.appendingPathComponent("Info.plist")) else { return false }
                    return old["CFBundleIdentifier"] as? String == bundleID
                }
                let destination = existing ?? appsDirectory.appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
                let replacement = appsDirectory.appendingPathComponent(UUID().uuidString + ".staging", isDirectory: true)
                let backup = appsDirectory.appendingPathComponent(UUID().uuidString + ".backup", isDirectory: true)
                try fileManager.moveItem(at: appBundle, to: replacement)
                defer { try? fileManager.removeItem(at: replacement) }
                if existing != nil { try fileManager.moveItem(at: destination, to: backup) }
                do { try fileManager.moveItem(at: replacement, to: destination) }
                catch {
                    if existing != nil {
                        do { try fileManager.moveItem(at: backup, to: destination) }
                        catch { throw IPAInstallError.copyFailed("Previous app preserved at " + backup.lastPathComponent) }
                    }
                    throw IPAInstallError.copyFailed(error.localizedDescription)
                }
                if existing != nil { try? fileManager.removeItem(at: backup) }
                result = .success(destination)
            } catch let error as IPAInstallError { result = .failure(error) }
            catch ZipError.unsupported { result = .failure(.unsupportedArchive) }
            catch ZipError.unsafePathEntry(let name) {
                result = .failure(.copyFailed("Entrada ZIP rejeitada por caminho inseguro: \(name)"))
            }
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
