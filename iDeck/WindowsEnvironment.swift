import Foundation
import Darwin

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    let graphicsConfig = GraphicsConfig()
    let audioManager = AudioManager()
    let steamManager = SteamManager()
    
    func hasRuntime(in prefix: String) -> Bool {
        guard PrefixInstaller.isPrefixInstalled(at: URL(fileURLWithPath: prefix)) else { return false }
        let assets = [
            "arm64ec-windows/xtajit64.dll",
            "arm64ec-windows/ntdll.dll",
            "arm64ec-windows/winemetal.dll",
            "aarch64-windows/winemetal.dll",
            "prefix-template.tar.gz"
        ]
        guard assets.allSatisfy({
            FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path)
        }) else { return false }
        // A missing plist is not evidence that the native runtime is absent.
        // Actual linker symbols and native capabilities determine readiness.
        // This still correctly rejects placeholder bridge-only builds.
        let requiredSymbols = [
            "fex_initialize",
            "wineserver_start",
            "wine_process_start",
            "madeira_get_present_count",
            "madeira_d3d12_canary_run",
            "ideck_madeira_launch_v1"
        ]
        let native = ideck_native_capabilities()
        guard native.metal_available, native.fex_linked, native.wine_linked,
              native.dxmt_linked, native.d3d12_linked, native.launcher_linked else {
            return false
        }
        return requiredSymbols.allSatisfy { name in
            name.withCString { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) != nil }
        }
    }

    func missingRuntimeComponents(in prefix: String) -> [String] {
        var missing: [String] = []
        if !PrefixInstaller.isPrefixInstalled(at: URL(fileURLWithPath: prefix)) {
            missing.append("Wine prefix")
        }
        let assets = [
            "arm64ec-windows/xtajit64.dll": "FEX ARM64EC",
            "arm64ec-windows/ntdll.dll": "Wine ARM64EC ntdll",
            "arm64ec-windows/winemetal.dll": "WineMetal ARM64EC",
            "aarch64-windows/winemetal.dll": "WineMetal ARM64",
            "prefix-template.tar.gz": "Wine prefix template"
        ]
        for (relativePath, label) in assets {
            if !FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL.appendingPathComponent(relativePath).path
            ) {
                missing.append(label)
            }
        }
        let native = ideck_native_capabilities()
        if !native.fex_linked { missing.append("FEX") }
        if !native.wine_linked { missing.append("Wine ARM64EC / wineserver") }
        if !native.dxmt_linked { missing.append("DXMT") }
        if !native.d3d12_linked { missing.append("D3D12") }
        if !native.launcher_linked { missing.append("Madeira native launcher") }
        if !native.metal_available { missing.append("Metal device") }
        return missing
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
        let wineRoot = URL(fileURLWithPath: winePrefixPath, isDirectory: true)
        let downloads = wineRoot.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
        let downloadPath = downloads.appendingPathComponent("SteamSetup.exe")
        guard PrefixInstaller.isPrefixInstalled(at: wineRoot),
              (try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)) != nil else {
            completion(false)
            return
        }
        
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
              binary.path.withCString({ ideck_native_validate_pe($0) }),
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
            unsetenv("MADEIRA_SCREEN_SRC")
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
        let limit = profile.fpsLimit == "Uncapped" ? 0 : RuntimeConfiguration.settings(for: profile).framesPerSecond
        let existing = getenv("DXMT_CONFIG").map { String(cString: $0) } ?? ""
        var options = existing.split(separator: ";").map(String.init).filter {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) != "d3d11.preferredMaxFrameRate"
        }
        options.append("d3d11.preferredMaxFrameRate = \(limit)")
        setenv("DXMT_CONFIG", options.joined(separator: ";"), 1)
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
        typealias NativeLaunch = @convention(c) (
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> Int32

        guard let symbol = "ideck_madeira_launch_v1".withCString({ dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }),
              !environment.isEmpty,
              FileManager.default.fileExists(atPath: executablePath),
              let payload = try? JSONSerialization.data(withJSONObject: [
                "version": 1,
                "arguments": arguments,
                "is32Bit": is32Bit,
                "isSteam": isSteam
              ]),
              let request = String(data: payload, encoding: .utf8) else {
            completion(-1)
            return
        }

        let launch = unsafeBitCast(symbol, to: NativeLaunch.self)
        DispatchQueue.global(qos: .userInitiated).async {
            let status = executablePath.withCString { executable in
                environment.withCString { prefix in
                    request.withCString { json in
                        launch(executable, prefix, json)
                    }
                }
            }
            DispatchQueue.main.async {
                completion(Int(status))
            }
        }
    }
}
