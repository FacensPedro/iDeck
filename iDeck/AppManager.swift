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
        let tempZipPath = fileManager.temporaryDirectory.appendingPathComponent(url.lastPathComponent + ".zip")
        let extractPath = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            if fileManager.fileExists(atPath: tempZipPath.path) {
                try fileManager.removeItem(at: tempZipPath)
            }
            try fileManager.copyItem(at: url, to: tempZipPath)
            
            // Note: In a real implementation, you need a ZIP extraction library here (like ZIPFoundation or Minizip)
            // This is a placeholder for the extraction process:
            // let process = Process()
            // process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // process.arguments = ["-q", tempZipPath.path, "-d", extractPath.path]
            // try process.run()
            // process.waitUntilExit()
            
            let payloadPath = extractPath.appendingPathComponent("Payload")
            if let appBundle = try? fileManager.contentsOfDirectory(at: payloadPath, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) {
                let destination = appsDirectory.appendingPathComponent(appBundle.lastPathComponent)
                
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                
                try fileManager.moveItem(at: appBundle, to: destination)
                refreshInstalledApps()
                completion(true)
            } else {
                completion(false)
            }
        } catch {
            completion(false)
        }
    }
}
