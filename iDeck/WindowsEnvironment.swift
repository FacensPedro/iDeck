import Foundation

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    
    func configureWine(prefix: String) {
        self.winePrefixPath = prefix
        setenv("WINEPREFIX", prefix, 1)
        setenv("WINEDEBUG", "-all", 1)
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
