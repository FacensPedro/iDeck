import Foundation
import Darwin

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    let graphicsConfig = GraphicsConfig()
    let audioManager = AudioManager()
    let steamManager = SteamManager()
    
    func hasRuntime(in prefix: String) -> Bool {
        guard let manifestURL = Bundle.main.url(forResource: "MadeiraRuntimeManifest", withExtension: "plist"),
              let data = try? Data(contentsOf: manifestURL),
              let rawManifest = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let manifest = rawManifest as? [String: Any],
              manifest["runtimeABI"] as? Int == 1,
              manifest["fexInProcess"] as? Bool == true,
              manifest["wineInProcess"] as? Bool == true,
              manifest["dxmtLinked"] as? Bool == true,
              manifest["d3d12Linked"] as? Bool == true else {
            return false
        }
        let requiredSymbols = [
            "fex_initialize",
            "wineserver_start",
            "wine_process_start",
            "madeira_dxmt_runtime_ready",
            "madeira_d3d12_runtime_ready"
        ]
        return requiredSymbols.allSatisfy { name in
            name.withCString { dlsym(RTLD_DEFAULT, $0) != nil }
        }
    }

    func configureWine(prefix: String) {
        self.winePrefixPath = prefix
        setenv("WINEPREFIX", prefix, 1)
        setenv("WINEDEBUG", "-all", 1)
        setenv("WINEARCH", "win64", 1)
        setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", prefix + "/drive_c/Program Files (x86)/Steam", 1)
        setenv("WINEDLLOVERRIDES", "dwrite=d;winhttp=n,b;crypt32=n,b;secur32=n,b;nsi=n,b;rpcrt4=n,b;wbemprox=n", 1)
        
        _ = audioManager.configureAudioSession()
        graphicsConfig.applyGraphicsEnvironment()
        steamManager.applySteamRegistryFixes(prefixPath: prefix)
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
                self?.execute(binary: downloadPath, is32Bit: true, isSteam: true, jitEnabler: jitEnabler) { success in
                    completion(success)
                }
            } catch {
                completion(false)
            }
        }
        task.resume()
    }
    
    func execute(binary: URL, arguments: String = "", is32Bit: Bool = false, isSteam: Bool = false, jitEnabler: JITEnabler, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: binary.path),
              let parsedArguments = BoxTranslator.parseArguments(arguments) else {
            completion(false)
            return
        }

        let architectureTranslator = BoxTranslator()
        architectureTranslator.translateAndRun(
            executablePath: binary.path,
            arguments: parsedArguments,
            environment: winePrefixPath,
            is32Bit: is32Bit,
            isSteam: isSteam,
            jitEnabler: jitEnabler
        ) { status in
            completion(status == 0)
        }
    }

    func applyGameProfile(_ profile: WindowsGameProfile) {
        if profile.resolution == "Device native" {
            unsetenv("MADEIRA_SCREEN_W")
            unsetenv("MADEIRA_SCREEN_H")
        } else {
            let parts = profile.resolution.split(separator: "x")
            if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
               (320...7680).contains(width), (240...4320).contains(height) {
                setenv("MADEIRA_SCREEN_W", String(width), 1)
                setenv("MADEIRA_SCREEN_H", String(height), 1)
                setenv("MADEIRA_SCREEN_SRC", "knob", 1)
            }
        }

        if profile.avxEnabled {
            setenv("MADEIRA_FEX_AVX", "1", 1)
        } else {
            unsetenv("MADEIRA_FEX_AVX")
        }

        if profile.metalFXEnabled {
            setenv("MVK_CONFIG_USE_METALFX", "1", 1)
        } else {
            unsetenv("MVK_CONFIG_USE_METALFX")
        }

        setenv("IDECK_PREFERRED_GRAPHICS_API", profile.graphicsAPI, 1)
        setenv("IDECK_FPS_LIMIT", profile.fpsLimit, 1)
    }
}

private class BoxTranslator {
    static func parseArguments(_ command: String) -> [String]? {
        guard command.utf8.count <= 4096 else { return nil }
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false
        var hasToken = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                hasToken = true
            } else if character == "\\" {
                escaping = true
                hasToken = true
            } else if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character.isWhitespace && !inQuotes {
                if hasToken {
                    result.append(current)
                    current = ""
                    hasToken = false
                    if result.count > 64 { return nil }
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }

        if escaping { current.append("\\") }
        guard !inQuotes else { return nil }
        if hasToken { result.append(current) }
        guard result.count <= 64 else { return nil }
        return result
    }

    func translateAndRun(executablePath: String, arguments: [String], environment: String, is32Bit: Bool, isSteam: Bool, jitEnabler: JITEnabler, completion: @escaping (Int) -> Void) {
        let boxBinary = is32Bit ? "\(environment)/usr/bin/box86" : "\(environment)/usr/bin/box64"
        let wineBinary = is32Bit ? "\(environment)/usr/bin/wine" : "\(environment)/usr/bin/wine64"
        var pid: pid_t = 0

        var args = [boxBinary, wineBinary, executablePath]
        args.append(contentsOf: arguments)

        if isSteam {
            args.append(contentsOf: ["-no-cef-sandbox", "-tcp", "-allopenal", "-login"])
        }

        var cArgs = args.map { strdup($0) }
        cArgs.append(nil)

        let env = ProcessInfo.processInfo.environment
        var cEnv = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        let spawnStatus = posix_spawn(&pid, boxBinary, nil, nil, cArgs, cEnv)

        for arg in cArgs { free(arg) }
        for e in cEnv { free(e) }

        if spawnStatus == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            completion(Int(status))
        } else {
            completion(-1)
        }
    }
}
