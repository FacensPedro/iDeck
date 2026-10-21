import Foundation
import UniformTypeIdentifiers

class AppManager: ObservableObject {
    @Published var installedApps: [URL] = []
    
    private let fileManager = FileManager.default
    private var appsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("GuestApps")
    }
    
    init() {
        if !fileManager.fileExists(atPath: appsDirectory.path) {
            try? fileManager.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        }
        refreshInstalledApps()
    }
    
    func refreshInstalledApps() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: appsDirectory, includingPropertiesForKeys: nil)
            installedApps = contents.filter { $0.hasDirectoryPath }
        } catch {
            installedApps = []
        }
    }
    
    func installIPA(from url: URL, completion: @escaping (Bool) -> Void) {
        let hasScope = url.startAccessingSecurityScopedResource()
        let fileManager = self.fileManager
        let appsDirectory = self.appsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }

            let extractPath = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fileManager.removeItem(at: extractPath) }

            var success = false
            do {
                // An .ipa is a ZIP archive; ZipExtractor rejects entries that escape extractPath.
                try ZipExtractor.extract(archive: url, to: extractPath)

                let payloadPath = extractPath.appendingPathComponent("Payload")
                let appBundle = try fileManager.contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" })

                if let appBundle = appBundle {
                    let destination = appsDirectory.appendingPathComponent(appBundle.lastPathComponent)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: appBundle, to: destination)
                    success = true
                }
            } catch {
                print("AppManager: IPA install failed: \(error)")
            }

            DispatchQueue.main.async {
                if success { self?.refreshInstalledApps() }
                completion(success)
            }
        }
    }
}
