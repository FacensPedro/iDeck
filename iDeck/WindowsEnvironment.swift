import Foundation

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    let graphicsConfig = GraphicsConfig()
    let audioManager = AudioManager()
    
    func configureWine(prefix: String) {
        self.winePrefixPath = prefix
        setenv("WINEPREFIX", prefix, 1)
        setenv("WINEDEBUG", "-all", 1)
        setenv("WINEARCH", "win64", 1)
        setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", prefix + "/drive_c/Program Files (x86)/Steam", 1)
        setenv("WINEDLLOVERRIDES", "dwrite=d", 1)
        
        _ = audioManager.configureAudioSession()
        graphicsConfig.applyGraphicsEnvironment()
    }
    
    func installAndRunSteam(completion: @escaping (Bool) -> Void) {
        let steamSetupURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
        let fileManager = FileManager.default
        let downloadPath = fileManager.temporaryDirectory.appendingPathComponent("SteamSetup.exe")
        
        if fileManager.fileExists(atPath: downloadPath.path) {
            try? fileManager.removeItem(at: downloadPath)
        }
        
        let task = URLSession.shared.downloadTask(with: steamSetupURL) { [weak self] localURL, _, error in
            guard let localURL = localURL, error == nil else {
                completion(false)
                return
            }
            
            do {
                try fileManager.moveItem(at: localURL, to: downloadPath)
                self?.execute(binary: downloadPath, is32Bit: true) { success in
                    completion(success)
                }
            } catch {
                completion(false)
            }
        }
        task.resume()
    }
    
    func execute(binary: URL, is32Bit: Bool = false, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            completion(false)
            return
        }
        
        let architectureTranslator = BoxTranslator()
        
        architectureTranslator.translateAndRun(executablePath: binary.path, environment: winePrefixPath, is32Bit: is32Bit) { status in
            completion(status == 0)
        }
    }
}

private class BoxTranslator {
    func translateAndRun(executablePath: String, environment: String, is32Bit: Bool, completion: @escaping (Int) -> Void) {
        let process = Process()
        let boxBinary = is32Bit ? "/usr/local/bin/box86" : "/usr/local/bin/box64"
        process.executableURL = URL(fileURLWithPath: boxBinary)
        process.arguments = ["wine", executablePath]
        
        process.environment = ProcessInfo.processInfo.environment
        
        do {
            try process.run()
            process.waitUntilExit()
            completion(Int(process.terminationStatus))
        } catch {
            completion(-1)
        }
    }
}
