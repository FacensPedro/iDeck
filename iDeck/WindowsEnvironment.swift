import Foundation
import Darwin

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
        setenv("WINEDLLOVERRIDES", "dwrite=d;winhttp=n,b;crypt32=n,b;secur32=n,b;nsi=n,b;rpcrt4=n,b", 1)
        
        _ = audioManager.configureAudioSession()
        graphicsConfig.applyGraphicsEnvironment()
    }
    
    func installAndRunSteam(jitEnabler: JITEnabler, completion: @escaping (Bool) -> Void) {
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
                self?.execute(binary: downloadPath, is32Bit: true, jitEnabler: jitEnabler) { success in
                    completion(success)
                }
            } catch {
                completion(false)
            }
        }
        task.resume()
    }
    
    func execute(binary: URL, is32Bit: Bool = false, jitEnabler: JITEnabler, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            completion(false)
            return
        }
        
        let architectureTranslator = BoxTranslator()
        
        architectureTranslator.translateAndRun(executablePath: binary.path, environment: winePrefixPath, is32Bit: is32Bit, jitEnabler: jitEnabler) { status in
            completion(status == 0)
        }
    }
}

private class BoxTranslator {
    func translateAndRun(executablePath: String, environment: String, is32Bit: Bool, jitEnabler: JITEnabler, completion: @escaping (Int) -> Void) {
        let boxBinary = is32Bit ? "/usr/local/bin/box86" : "/usr/local/bin/box64"
        var pid: pid_t = 0
        
        let args = [boxBinary, "wine", executablePath]
        var cArgs = args.map { strdup($0) }
        cArgs.append(nil)
        
        let env = ProcessInfo.processInfo.environment
        var cEnv = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        
        let spawnStatus = posix_spawn(&pid, boxBinary, nil, nil, cArgs, cEnv)
        
        for arg in cArgs { free(arg) }
        for e in cEnv { free(e) }
        
        if spawnStatus == 0 {
            jitEnabler.activate(for: pid, useVPN: false, pairingFileURL: nil) { jitSuccess in
                if jitSuccess {
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                    completion(Int(status))
                } else {
                    kill(pid, SIGKILL)
                    completion(-1)
                }
            }
        } else {
            completion(-1)
        }
    }
}
