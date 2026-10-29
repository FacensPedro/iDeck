import Foundation
import Darwin

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    private var steamRegistryInitializedPrefixes = Set<String>()
    let graphicsConfig = GraphicsConfig()
    let audioManager = AudioManager()
    let steamManager = SteamManager()
    
    func hasRuntime(in prefix: String) -> Bool {
        guard PrefixInstaller.isPrefixInstalled(at: URL(fileURLWithPath: prefix)) else { return false }
        let assets = [
            "arm64ec-windows/xtajit64.dll",
            "arm64ec-windows/ntdll.dll",
            "arm64ec-windows/kernel32.dll",
            "arm64ec-windows/kernelbase.dll",
            "arm64ec-windows/user32.dll",
            "arm64ec-windows/gdi32.dll",
            "arm64ec-windows/d3d11.dll",
            "arm64ec-windows/dxgi.dll",
            "arm64ec-windows/madeira_d3d12.dll",
            "arm64ec-windows/d3d12.dll",
            "arm64ec-windows/d3d12core.dll",
            "arm64ec-windows/winemetal.dll",
            "arm64ec-windows/dcomp.dll",
            "arm64ec-windows/ktmw32.dll",
            "arm64ec-windows/faultrep.dll",
            "arm64ec-windows/xaudio2_7.dll",
            "arm64ec-windows/d3dx11_43.dll",
            "arm64ec-windows/d3dcompiler_47.dll",
            "arm64ec-windows/dinput8.dll",
            "aarch64-windows/d3d11.dll",
            "aarch64-windows/dxgi.dll",
            "aarch64-windows/winemetal.dll",
            "nls/locale.nls",
            "d3d12/libmetalirconverter.dylib",
            "d3d12/canary_vs.dxil",
            "d3d12/canary_ps.dxil",
            "cacert.pem",
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
            "wine_process_is_running",
            "madeira_display_set_layer",
            "macdrv_functions",
            "winios_screen_size",
            "winios_display_mode_changed",
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

    func hasWoW64Runtime() -> Bool {
        let bundle = Bundle.main.bundleURL
        let manifestURL = bundle.appendingPathComponent("MadeiraRuntimeManifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              manifest["wow64Enabled"] as? Bool == true else {
            return false
        }

        let assets = [
            "i386-windows/ntdll.dll",
            "i386-windows/kernel32.dll",
            "i386-windows/user32.dll",
            "i386-windows/d3d11.dll",
            "i386-windows/dxgi.dll",
            "aarch64-windows/xtajit.dll",
            "aarch64-windows/wow64.dll",
            "aarch64-windows/wow64win.dll"
        ]
        return assets.allSatisfy { name in
            let file = bundle.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attributes[.size] as? NSNumber, size.intValue >= 1024,
                  let handle = try? FileHandle(forReadingFrom: file) else {
                return false
            }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 2)) == Data([0x4d, 0x5a])
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
            "arm64ec-windows/kernel32.dll": "Wine kernel32",
            "arm64ec-windows/kernelbase.dll": "Wine kernelbase",
            "arm64ec-windows/user32.dll": "Wine user32",
            "arm64ec-windows/gdi32.dll": "Wine gdi32",
            "arm64ec-windows/d3d11.dll": "DXMT D3D11",
            "arm64ec-windows/dxgi.dll": "DXMT DXGI",
            "arm64ec-windows/madeira_d3d12.dll": "Madeira native D3D12 frontend",
            "arm64ec-windows/d3d12.dll": "D3D12 frontend",
            "arm64ec-windows/d3d12core.dll": "D3D12 core",
            "arm64ec-windows/winemetal.dll": "WineMetal ARM64EC",
            "arm64ec-windows/dcomp.dll": "Wine DirectComposition",
            "arm64ec-windows/ktmw32.dll": "Wine KTM transactions",
            "arm64ec-windows/faultrep.dll": "Wine error-reporting compatibility",
            "arm64ec-windows/xaudio2_7.dll": "Wine XAudio2",
            "arm64ec-windows/d3dx11_43.dll": "Wine D3DX11",
            "arm64ec-windows/d3dcompiler_47.dll": "Wine D3D shader compiler",
            "arm64ec-windows/dinput8.dll": "Wine DirectInput",
            "aarch64-windows/d3d11.dll": "Wine D3D11 ARM64",
            "aarch64-windows/dxgi.dll": "Wine DXGI ARM64",
            "aarch64-windows/winemetal.dll": "WineMetal ARM64",
            "nls/locale.nls": "Wine locale data",
            "d3d12/libmetalirconverter.dylib": "Metal shader converter",
            "d3d12/canary_vs.dxil": "D3D12 vertex shader fixture",
            "d3d12/canary_ps.dxil": "D3D12 pixel shader fixture",
            "cacert.pem": "Wine HTTPS certificate trust store",
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
        for (name, label) in [
            ("madeira_display_set_layer", "Metal display bridge"),
            ("macdrv_functions", "Wine Metal macdrv exports"),
            ("winios_screen_size", "Wine virtual screen bridge"),
            ("winios_display_mode_changed", "Wine display mode bridge"),
            ("wine_process_is_running", "Wine process readiness")
        ] {
            if name.withCString({ dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) == nil }) {
                missing.append(label)
            }
        }
        if !native.metal_available { missing.append("Metal device") }
        return missing
    }

    func configureWine(prefix: String) {
        self.winePrefixPath = prefix
        setenv("WINEPREFIX", prefix, 1)
        if ProcessInfo.processInfo.environment["IDECK_WINE_DIAGNOSTICS"] == "1" {
            // Madeira's Wine process thread configures WINEDEBUG itself.
            // Use its supported flag to request detailed native traces.
            setenv("MADEIRA_DEBUG_VERBOSE", "1", 1)
            setenv("WINEDEBUG", "err+all", 1)
        } else {
            // Match Madeira's lightweight default; do not suppress errors.
            setenv("WINEDEBUG", "err+all,err-virtual,fixme-d3dcompiler", 1)
        }
        setenv("WINEARCH", "win64", 1)
        setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", prefix + "/drive_c/Program Files (x86)/Steam", 1)
        
        _ = audioManager.configureAudioSession()
        graphicsConfig.applyGraphicsEnvironment()
        // This reads and may rewrite user.reg. Do it only on the first
        // configuration of each existing prefix, not before every game.
        if !steamRegistryInitializedPrefixes.contains(prefix) {
            if FileManager.default.fileExists(atPath: prefix + "/user.reg") {
                steamManager.applySteamRegistryFixes(prefixPath: prefix)
                steamRegistryInitializedPrefixes.insert(prefix)
            }
        }
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
                guard let self, !Self.isPE32WindowsExecutable(downloadPath) || self.hasWoW64Runtime() else {
                    SteamLog.event("[wine-launch] SteamSetup requires WoW64 i386 runtime")
                    completion(false)
                    return
                }
                self.execute(binary: downloadPath, is32Bit: Self.isPE32WindowsExecutable(downloadPath), isSteam: true, jitEnabler: jitEnabler) { status in
                    completion(status == 0)
                }
            } catch {
                completion(false)
            }
        }
        task.resume()
    }
    
    private static func isPE32WindowsExecutable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            guard let dos = try handle.read(upToCount: 64), dos.count == 64,
                  dos[0] == 0x4d, dos[1] == 0x5a else { return false }
            let offset = UInt64(dos[0x3c]) | (UInt64(dos[0x3d]) << 8) |
                         (UInt64(dos[0x3e]) << 16) | (UInt64(dos[0x3f]) << 24)
            guard offset >= 64 && offset < 64 * 1024 * 1024 else { return false }
            try handle.seek(toOffset: offset)
            guard let pe = try handle.read(upToCount: 26), pe.count == 26,
                  pe[0] == 0x50, pe[1] == 0x45, pe[2] == 0, pe[3] == 0 else {
                return false
            }
            let machine = UInt16(pe[4]) | (UInt16(pe[5]) << 8)
            let optionalMagic = UInt16(pe[24]) | (UInt16(pe[25]) << 8)
            return machine == 0x014c && optionalMagic == 0x010b
        } catch {
            return false
        }
    }

    func execute(binary: URL, arguments: String = "", is32Bit: Bool = false, isSteam: Bool = false,
                 steamAppID: UInt32? = nil, steamInstallDirectory: URL? = nil,
                 steamWorkingDirectory: URL? = nil,
                 jitEnabler: JITEnabler, completion: @escaping (Int) -> Void) {
        guard FileManager.default.fileExists(atPath: binary.path),
              binary.path.withCString({ ideck_native_validate_pe($0) }),
              let parsedArguments = BoxTranslator.parseArguments(arguments) else {
            SteamLog.event("[wine-launch] invalid executable or Windows launch arguments")
            completion(Int(EINVAL))
            return
        }

        let needsWoW64 = is32Bit || Self.isPE32WindowsExecutable(binary)
        guard !needsWoW64 || hasWoW64Runtime() else {
            SteamLog.event("[wine-launch] rejected PE32 i386 executable: complete WoW64 runtime is missing")
            completion(Int(ENOTSUP))
            return
        }

        let architectureTranslator = BoxTranslator()
        architectureTranslator.translateAndRun(
            executablePath: binary.path,
            arguments: parsedArguments,
            environment: winePrefixPath,
            is32Bit: needsWoW64,
            isSteam: isSteam,
            steamAppID: steamAppID,
            steamInstallDirectory: steamInstallDirectory,
            steamWorkingDirectory: steamWorkingDirectory,
            jitEnabler: jitEnabler
        ) { status in
            if status != 0 { SteamLog.event("[wine-launch] native launch failure code=\(status)") }
            completion(status)
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

        if profile.keepChildProcessesRunning {
            setenv("MADEIRA_WAIT_CHILDREN", "1", 1)
        } else {
            unsetenv("MADEIRA_WAIT_CHILDREN")
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
        WindowsLaunchArguments.parse(command)
    }

    func translateAndRun(executablePath: String, arguments: [String], environment: String,
                         is32Bit: Bool, isSteam: Bool,
                         steamAppID: UInt32?, steamInstallDirectory: URL?,
                         steamWorkingDirectory: URL?,
                         jitEnabler: JITEnabler, completion: @escaping (Int) -> Void) {
        typealias NativeLaunch = @convention(c) (
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> Int32

        var launchDetails: [String: Any] = [
            "version": 1,
            "arguments": arguments,
            "is32Bit": is32Bit,
            "isSteam": isSteam
        ]
        if let steamAppID, let steamInstallDirectory {
            launchDetails["steamAppID"] = Int(steamAppID)
            launchDetails["steamInstallDirectory"] = steamInstallDirectory.standardizedFileURL.path
            if let steamWorkingDirectory {
                launchDetails["steamWorkingDirectory"] = steamWorkingDirectory.standardizedFileURL.path
            }
        }
        guard let symbol = "ideck_madeira_launch_v1".withCString({ dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) }),
              !environment.isEmpty,
              FileManager.default.fileExists(atPath: executablePath),
              let payload = try? JSONSerialization.data(withJSONObject: launchDetails),
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
