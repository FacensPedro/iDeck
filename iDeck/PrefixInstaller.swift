import Foundation

class PrefixInstaller: ObservableObject {
    @Published var isInstalling: Bool = false
    @Published var progress: Float = 0.0
    
    func installWinePrefix(to destinationPath: String, completion: @escaping (Bool) -> Void) {
        isInstalling = true
        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: destinationPath)
        let rootfsURL = URL(string: "https://raw.githubusercontent.com/FacensPedro/iDeck/main/madeira_env.zip")!
        let tempFile = fileManager.temporaryDirectory.appendingPathComponent("madeira_env.zip")
        
        if fileManager.fileExists(atPath: destinationPath) && !try! fileManager.contentsOfDirectory(atPath: destinationPath).isEmpty {
            self.isInstalling = false
            completion(true)
            return
        }
        
        let task = URLSession.shared.downloadTask(with: rootfsURL) { localURL, response, error in
            guard let localURL = localURL, error == nil else {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    completion(false)
                }
                return
            }
            
            do {
                if fileManager.fileExists(atPath: tempFile.path) {
                    try fileManager.removeItem(at: tempFile)
                }
                try fileManager.moveItem(at: localURL, to: tempFile)
                
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                }
                
                DispatchQueue.main.async {
                    self.isInstalling = false
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    completion(false)
                }
            }
        }
        task.resume()
    }
}
