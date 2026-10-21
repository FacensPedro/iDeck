import Foundation

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    
    func configureWine(prefix: String) {
        self.winePrefixPath = prefix
        setenv("WINEPREFIX", prefix, 1)
        setenv("WINEDEBUG", "-all", 1)
        setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", prefix + "/drive_c/Program Files (x86)/Steam", 1)
        setenv("WINEDLLOVERRIDES", "dwrite=d;dxgi=n", 1)
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
                self?.execute(binary: downloadPath) { success in
                    completion(success)
                }
            } catch {
                completion(false)
            }
        }
        task.resume()
    }
    
    func execute(binary: URL, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            completion(false)
            return
        }
        
        let architectureTranslator = Box64Translator()
        
        architectureTranslator.translateAndRun(executablePath: binary.path, environment: winePrefixPath) { status in
            completion(status == 0)
        }
    }
}

private class Box64Translator {
    func translateAndRun(executablePath: String, environment: String, completion: @escaping (Int) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/box64")
        process.arguments = ["wine", executablePath]
        
        var environmentDict = ProcessInfo.processInfo.environment
        environmentDict["WINEPREFIX"] = environment
        environmentDict["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = environment + "/drive_c/Program Files (x86)/Steam"
        environmentDict["WINEDLLOVERRIDES"] = "dwrite=d;dxgi=n"
        
        process.environment = environmentDict
        
        do {
            try process.run()
            process.waitUntilExit()
            completion(Int(process.terminationStatus))
        } catch {
            completion(-1)
        }
    }
}
