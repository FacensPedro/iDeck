import Foundation

class SteamManager {
    func applySteamRegistryFixes(prefixPath: String) {
        let registryPath = prefixPath + "/user.reg"
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: registryPath) else { return }
        
        do {
            var registryContent = try String(contentsOfFile: registryPath, encoding: .utf8)
            
            let overrides = """
            
            [Software\\\\Wine\\\\AppDefaults\\\\steam.exe\\\\DllOverrides]
            "dwrite"="d"
            "winhttp"="n,b"
            "crypt32"="n,b"
            "secur32"="n,b"
            
            [Software\\\\Valve\\\\Steam]
            "DWriteEnable"="0"
            "CEFDisableGPU"="1"
            "SmoothScrollWebviews"="0"
            
            """
            
            if !registryContent.contains("AppDefaults\\\\steam.exe") {
                registryContent.append(overrides)
                try registryContent.write(toFile: registryPath, atomically: true, encoding: .utf8)
            }
        } catch {
            print("SteamManager: Registry override failed.")
        }
    }
}
