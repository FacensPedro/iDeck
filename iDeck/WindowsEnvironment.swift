import Foundation
import Darwin
import UIKit

enum MadeiraBundleIdentity {
    static let missingRuntimeMessage = "This iDeck IPA contains only the interface. Download iDeck.ipa from an iOS Build Run workflow with Require Madeira runtime enabled."

    static var nativeManifest: [String: Any]? {
        let file = Bundle.main.bundleURL.appendingPathComponent("MadeiraRuntimeManifest.plist")
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              plist["fexInProcess"] as? Bool == true,
              plist["wineInProcess"] as? Bool == true,
              plist["dxmtLinked"] as? Bool == true,
              let graphics = plist["graphicsBackend"] as? String,
              graphics == "d3d11" || graphics == "d3d12",
              plist["d3d12Linked"] as? Bool == (graphics == "d3d12") else {
            return nil
        }
        return plist
    }

    static var isNative: Bool { nativeManifest != nil }

    /// Each backend's availability in this IPA. DXMT (D3D11, D3D10, DXGI)
    /// is part of every native profile; Madeira D3D12 is added next to it
    /// by the unified (and legacy d3d12) profile, never in its place.
    static var d3d11Available: Bool { nativeManifest != nil }
    static var d3d12Available: Bool {
        guard let manifest = nativeManifest else { return false }
        return manifest["d3d12Available"] as? Bool ?? (manifest["graphicsBackend"] as? String == "d3d12")
    }
    /// "unified", "d3d11" or "d3d12" (legacy), as recorded at build time.
    static var graphicsProfile: String {
        guard let manifest = nativeManifest else { return "none" }
        return manifest["graphicsProfile"] as? String
            ?? ((manifest["graphicsBackend"] as? String) == "d3d12" ? "unified" : "d3d11")
    }

    static var profile: [String: Any] {
        let path = Bundle.main.bundleURL.appendingPathComponent("iDeckRuntimeProfile.plist")
        guard let data = try? Data(contentsOf: path),
              let value = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              value["profileSchema"] as? Int == 1,
              let manifest = nativeManifest,
              value["runtimeKind"] as? String == "madeira-native",
              value["graphicsBackend"] as? String == manifest["graphicsBackend"] as? String,
              value["wow64Enabled"] as? Bool == manifest["wow64Enabled"] as? Bool else {
            if let manifest = nativeManifest {
                return [
                    "runtimeKind": "madeira-native",
                    "graphicsBackend": manifest["graphicsBackend"] ?? "none",
                    "wow64Enabled": manifest["wow64Enabled"] ?? false,
                    "wineMonoBundled": false,
                    "metalShaderConverterBundled": manifest["d3d12Linked"] ?? false
                ]
            }
            return [
                "runtimeKind": "interface-only", "graphicsBackend": "none",
                "wow64Enabled": false, "wineMonoBundled": false,
                "metalShaderConverterBundled": false
            ]
        }
        return value
    }
}

class WindowsEnvironment {
    private var winePrefixPath: String = ""
    private var steamRegistryInitializedPrefixes = Set<String>()
    let graphicsConfig = GraphicsConfig()
    let audioManager = AudioManager()
    let steamManager = SteamManager()
    /// The profile's Vulkan/OpenGL choices, applied when the executable is known.
    private var sessionVulkanMode = "Automatic"
    private var sessionUseRecommended = true
    private var sessionCodeChecks = "Automatic"
    private var sessionGraphicsAPI = "Automatic"
    private var sessionOpenGLBackend = "Automatic"
    /// MetalFX spatial upscale factor for this launch (nil = off).
    private var sessionMetalFXFactor: Double?
    
    private var nativeGraphicsBackend: String? {
        MadeiraBundleIdentity.nativeManifest?["graphicsBackend"] as? String
    }

    func hasRuntime(in prefix: String) -> Bool {
        guard PrefixInstaller.isPrefixInstalled(at: URL(fileURLWithPath: prefix)),
              let backend = nativeGraphicsBackend else { return false }
        var assets = [
            "arm64ec-windows/xtajit64.dll",
            "arm64ec-windows/ntdll.dll",
            "arm64ec-windows/kernel32.dll",
            "arm64ec-windows/kernelbase.dll",
            "arm64ec-windows/user32.dll",
            "arm64ec-windows/gdi32.dll",
            "arm64ec-windows/d3d11.dll",
            "arm64ec-windows/dxgi.dll",
            "arm64ec-windows/winemetal.dll",
            "arm64ec-windows/dcomp.dll",
            "compat/love/lua51.dll",
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
            "cacert.pem",
            "prefix-template.tar.gz"
        ]
        if backend == "d3d12" {
            assets += ["arm64ec-windows/madeira_d3d12.dll", "arm64ec-windows/d3d12.dll",
                       "arm64ec-windows/d3d12core.dll", "d3d12/libmetalirconverter.dylib",
                       "d3d12/canary_vs.dxil", "d3d12/canary_ps.dxil"]
        }
        guard assets.allSatisfy({
            FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path)
        }) else { return false }
        // A missing plist is not evidence that the native runtime is absent.
        // Actual linker symbols and native capabilities determine readiness.
        // This still correctly rejects placeholder bridge-only builds.
        var requiredSymbols = [
            "fex_initialize",
            "wineserver_start",
            "wine_process_start",
            "wine_process_is_running",
            "madeira_display_set_layer",
            "macdrv_functions",
            "winios_screen_size",
            "winios_display_mode_changed",
            "madeira_get_present_count",
            "ideck_madeira_launch_v1"
        ]
        if backend == "d3d12" { requiredSymbols.append("madeira_d3d12_canary_run") }
        let native = ideck_native_capabilities()
        guard native.metal_available, native.fex_linked, native.wine_linked,
              native.dxmt_linked, native.launcher_linked,
              (backend == "d3d11" || native.d3d12_linked) else {
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
            if name.hasPrefix("i386-windows/") {
                return file.path.withCString { ideck_native_pe_machine($0) == 0x014c }
            }
            return (try? handle.read(upToCount: 2)) == Data([0x4d, 0x5a])
        }
    }

    func missingRuntimeComponents(in prefix: String) -> [String] {
        var missing: [String] = []
        let backend = nativeGraphicsBackend
        if backend == nil { missing.append("Verified Madeira graphics manifest") }
        if !PrefixInstaller.isPrefixInstalled(at: URL(fileURLWithPath: prefix)) {
            missing.append("Wine prefix")
        }
        var assets = [
            "arm64ec-windows/xtajit64.dll": "FEX ARM64EC",
            "arm64ec-windows/ntdll.dll": "Wine ARM64EC ntdll",
            "arm64ec-windows/kernel32.dll": "Wine kernel32",
            "arm64ec-windows/kernelbase.dll": "Wine kernelbase",
            "arm64ec-windows/user32.dll": "Wine user32",
            "arm64ec-windows/gdi32.dll": "Wine gdi32",
            "arm64ec-windows/d3d11.dll": "DXMT D3D11",
            "arm64ec-windows/dxgi.dll": "DXMT DXGI",
            "arm64ec-windows/winemetal.dll": "WineMetal ARM64EC",
            "arm64ec-windows/dcomp.dll": "Wine DirectComposition",
            "compat/love/lua51.dll": "LuaJIT GC64 compatibility",
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
            "cacert.pem": "Wine HTTPS certificate trust store",
            "prefix-template.tar.gz": "Wine prefix template"
        ]
        if backend == "d3d12" {
            assets["arm64ec-windows/madeira_d3d12.dll"] = "Madeira native D3D12 frontend"
            assets["arm64ec-windows/d3d12.dll"] = "D3D12 frontend"
            assets["arm64ec-windows/d3d12core.dll"] = "D3D12 core"
            assets["d3d12/libmetalirconverter.dylib"] = "Metal shader converter"
            assets["d3d12/canary_vs.dxil"] = "D3D12 vertex shader fixture"
            assets["d3d12/canary_ps.dxil"] = "D3D12 pixel shader fixture"
        }
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
        if backend == "d3d12" && !native.d3d12_linked { missing.append("D3D12") }
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
        url.path.withCString { ideck_native_pe_machine($0) == 0x014c }
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

        let actualMachine = binary.path.withCString { ideck_native_pe_machine($0) }
        guard actualMachine == 0x014c || actualMachine == 0x8664 else {
            SteamLog.event("[wine-launch] unsupported or truncated PE image")
            completion(Int(EINVAL))
            return
        }
        let needsWoW64 = actualMachine == 0x014c
        if is32Bit && !needsWoW64 {
            SteamLog.event("[wine-launch] correcting stale PE32 flag for x64 executable")
        }
        guard !needsWoW64 || hasWoW64Runtime() else {
            SteamLog.event("[wine-launch] rejected PE32 i386 executable: complete WoW64 runtime is missing")
            completion(Int(ENOTSUP))
            return
        }
        writeSessionGraphicsConfig(binary: binary, is32Bit: needsWoW64,
                                   steamAppID: steamAppID, steamInstallDirectory: steamInstallDirectory)

        // The engine's own switch for the game's API preference goes last,
        // after the game's and the user's arguments.
        let engineSwitch = prepareGraphicsAPI(binary: binary)
        let launchArguments = parsedArguments + engineSwitch.filter { !parsedArguments.contains($0) }
        let architectureTranslator = BoxTranslator()
        architectureTranslator.translateAndRun(
            executablePath: binary.path,
            arguments: launchArguments,
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

    /// Whether this IPA carries Madeira's OpenGL/Vulkan runtime (gl/ and vulkan/).
    static var hasGLVulkanRuntime: Bool {
        let bundle = Bundle.main.bundleURL
        return ["gl/libMoltenVK.dylib", "vulkan/arm64ec-windows/winevulkan.dll",
                "vulkan/arm64ec-windows/vulkan-1.dll"].allSatisfy {
            FileManager.default.fileExists(atPath: bundle.appendingPathComponent($0).path)
        }
    }

    /// Graphics APIs a game can use: its executable and, for Unity games,
    /// UnityPlayer.dll next to it (where the engine's renderer lives). Read
    /// in C (GraphicsAPIScan.c) from import tables and LoadLibrary strings.
    static func graphicsAPIs(of binary: URL) -> UInt32 {
        var bits = binary.path.withCString { ideck_pe_graphics_apis($0) }
        let unity = binary.deletingLastPathComponent().appendingPathComponent("UnityPlayer.dll")
        if FileManager.default.fileExists(atPath: unity.path) {
            bits |= unity.path.withCString { ideck_pe_graphics_apis($0) }
        }
        return bits
    }

    static func executableReferencesVulkan(_ url: URL) -> Bool {
        graphicsAPIs(of: url) & UInt32(IDECK_API_VULKAN) != 0
    }

    /// "D3D11, D3D12, DXGI" for the launch log.
    static func describeGraphicsAPIs(_ bits: UInt32) -> String {
        let names: [(Int, String)] = [(IDECK_API_D3D9, "D3D9"), (IDECK_API_D3D10, "D3D10"), (IDECK_API_D3D11, "D3D11"),
                                        (IDECK_API_D3D12, "D3D12"), (IDECK_API_DXGI, "DXGI"),
                                        (IDECK_API_VULKAN, "Vulkan"), (IDECK_API_OPENGL, "OpenGL")]
        let found = names.filter { bits & UInt32($0.0) != 0 }.map(\.1)
        return found.isEmpty ? "none found" : found.joined(separator: ", ")
    }

    /// The game engine's own switch for a Direct3D version, if it has one:
    /// Unity (UnityPlayer.dll next to the game) and Unreal (Win64 shipping
    /// builds). Other games choose their API themselves.
    static func engineAPIArgument(binary: URL, preferD3D12: Bool) -> String? {
        let folder = binary.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("UnityPlayer.dll").path) {
            return preferD3D12 ? "-force-d3d12" : "-force-d3d11"
        }
        let path = binary.path
        if path.hasSuffix("-Win64-Shipping.exe") || path.contains("/Binaries/Win64/") {
            return preferD3D12 ? "-dx12" : "-dx11"
        }
        return nil
    }

    /// Logs the APIs the game uses, reports one this IPA cannot run, and
    /// returns the engine switch for the game's API preference, if any.
    private func prepareGraphicsAPI(binary: URL) -> [String] {
        let bits = Self.graphicsAPIs(of: binary)
        let d3d11 = bits & UInt32(IDECK_API_D3D11) != 0
        let d3d12 = bits & UInt32(IDECK_API_D3D12) != 0
        let d3d12Available = MadeiraBundleIdentity.d3d12Available
        SteamLog.event("[graphics] \(binary.lastPathComponent) uses: \(Self.describeGraphicsAPIs(bits)); "
                       + "this IPA: D3D11 (DXMT) yes, D3D12 (Madeira) \(d3d12Available ? "yes" : "no")")
        if d3d12 && !d3d11 && !d3d12Available {
            AppLog.record("[graphics] \(binary.lastPathComponent) needs Direct3D 12, which this IPA cannot run: "
                          + "it was built with the d3d11 profile. Use an IPA built with the unified profile.")
        }
        guard sessionGraphicsAPI != "Automatic" else { return [] }
        let wantsD3D12 = sessionGraphicsAPI == "D3D12"
        if wantsD3D12 && !d3d12Available {
            AppLog.record("[graphics] Direct3D 12 preference ignored: this IPA cannot run Direct3D 12 (d3d11 profile).")
            return []
        }
        if (wantsD3D12 && !d3d12) || (!wantsD3D12 && !d3d11) {
            AppLog.record("[graphics] \(wantsD3D12 ? "Direct3D 12" : "Direct3D 11") preference ignored: "
                          + "\(binary.lastPathComponent) does not use that API.")
            return []
        }
        guard let argument = Self.engineAPIArgument(binary: binary, preferD3D12: wantsD3D12) else {
            AppLog.record("[graphics] API preference ignored: \(binary.lastPathComponent) has no known engine switch "
                          + "(Unity or Unreal); the game chooses its API itself.")
            return []
        }
        SteamLog.event("[graphics] API preference: passing \(argument) to the game's engine")
        return [argument]
    }

    /// C:\ path of a file inside the prefix's drive_c, or nil.
    static func windowsPath(_ url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard let index = parts.lastIndex(of: "drive_c") else { return nil }
        return "C:\\" + parts[(index + 1)...].joined(separator: "\\")
    }

    /// The recommendation for the program being launched; `.standard` for an
    /// unrecognised game.
    static func recommendation(binary: URL, steamAppID: UInt32?, steamInstallDirectory: URL?) -> GameRecommendation {
        let exists: (String) -> Bool = { windows in
            guard let root = binary.standardizedFileURL.pathComponents.lastIndex(of: "drive_c") else { return false }
            let drive = NSString.path(withComponents: Array(binary.standardizedFileURL.pathComponents[...root]))
            let relative = windows.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
            return FileManager.default.fileExists(atPath: drive + "/" + relative)
        }
        if let steamAppID, let folder = steamInstallDirectory.flatMap(windowsPath),
           let match = GameRecommendations.match(windowsPath: folder, steamAppID: Int(steamAppID), fileExists: exists) {
            return match
        }
        if let path = windowsPath(binary),
           let match = GameRecommendations.match(windowsPath: path, steamAppID: steamAppID.map(Int.init), fileExists: exists) {
            return match
        }
        return GameRecommendations.standard
    }

    /// Writes this launch's lines of Madeira's per-game config (MADEIRA_CFG_GAME,
    /// read after Documents/madeira.cfg so these keys win). `vulkan = moltenvk`
    /// makes the bridge link winevulkan/vulkan-1 into the prefix and point
    /// winevulkan at gl/libMoltenVK.dylib; `gl-backend` picks Zink or OpenGL ES.
    /// Upstream binds no 32-bit Vulkan table yet, so Vulkan is x64-only.
    private func writeSessionGraphicsConfig(binary: URL, is32Bit: Bool,
                                            steamAppID: UInt32? = nil, steamInstallDirectory: URL? = nil) {
        var lines = ["# Written by iDeck for this launch: \(binary.lastPathComponent)"]
        if sessionUseRecommended {
            let recommendation = Self.recommendation(binary: binary, steamAppID: steamAppID,
                                                     steamInstallDirectory: steamInstallDirectory)
            lines += recommendation.config.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            SteamLog.event("[wine-launch] recommended settings: \(recommendation.id) v\(recommendation.version)")
        }
        let runtime = Self.hasGLVulkanRuntime
        switch sessionVulkanMode {
        case "Off":
            lines.append("vulkan = off")
        case "On" where runtime && !is32Bit:
            lines.append("vulkan = moltenvk")
        case "Automatic" where runtime && !is32Bit && Self.executableReferencesVulkan(binary):
            lines.append("vulkan = moltenvk")
        default:
            break
        }
        // Automatic leaves FEX's code checks as Madeira ships them (mtrack):
        // Madeira's Wine and FEX handle Mono/Unity code heaps with that mode.
        // Forcing full checks for Mono games broke Cuphead, which runs in
        // Madeira; its earlier crash came from a JIT pool too small for Mono's
        // code heap. "Compatible" and "Fast" stay available per game.
        // As Madeira (BCDLaunch.realSuspend): a Unity IL2CPP game's garbage
        // collector suspends its threads and reads their registers, which
        // needs Wine to stop the thread for real. Only for those games.
        if FileManager.default.fileExists(atPath: binary.deletingLastPathComponent()
            .appendingPathComponent("GameAssembly.dll").path) {
            setenv("MADEIRA_REAL_SUSPEND", "1", 1)
            SteamLog.event("[wine-launch] Unity IL2CPP game: real thread suspension on")
        } else {
            unsetenv("MADEIRA_REAL_SUSPEND")
        }
        switch sessionCodeChecks {
        case "Compatible":
            lines.append("env.FEX_SMCCHECKS = full")
        case "Fast":
            lines.append("env.FEX_SMCCHECKS = mtrack")
        default:
            break
        }
        // madeira-d3d12 reads its MetalFX factor from the game's config lines;
        // DXMT gets the same factor through DXMT_CONFIG (applyGameProfile).
        if let factor = sessionMetalFXFactor {
            lines.append(String(format: "metalfx-upscale = %.2f", factor))
        }
        switch sessionOpenGLBackend {
        case "Desktop OpenGL": lines.append("gl-backend = zink")
        case "OpenGL ES": lines.append("gl-backend = gles")
        default: break
        }
        if lines.count == 1 {
            unsetenv("MADEIRA_CFG_GAME")
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck/GameConfig", isDirectory: true)
        let file = directory.appendingPathComponent("session.cfg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            setenv("MADEIRA_CFG_GAME", file.path, 1)
            SteamLog.event("[wine-launch] graphics: " + lines.dropFirst().joined(separator: "; "))
        } catch {
            unsetenv("MADEIRA_CFG_GAME")
            SteamLog.event("[wine-launch] could not write the game graphics config: \(error.localizedDescription)")
        }
    }

    func applyGameProfile(_ profile: WindowsGameProfile) {
        // A previous Madeira Dock launch leaves its host switches in the
        // process environment; only a new Dock launch sets them again.
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN",
                    "MADEIRA_STEAM_HOST_LAUNCH", "MADEIRA_STEAM_HOST_APPID", "MADEIRA_STEAM_HOST_LAUNCH_OPTION",
                    "MADEIRA_STEAM_HOST_CLIENT_DIR", "MADEIRA_STEAM_HOST_EXPECTED_INSTALL", "MADEIRA_STEAM_HOST_LOG",
                    "MADEIRA_STEAM_HOST_ARGUMENTS", "MADEIRA_STEAM_HOST_CEG", "MADEIRA_JIT_IMAGE_RETIRE",
                    "MADEIRA_IMAGE_MAP_GUARD", "MADEIRA_DOCK_AUTH_FILE", "MADEIRA_DOCK_OFFLINE"] {
            unsetenv(key)
        }
        sessionUseRecommended = profile.useRecommended
        sessionCodeChecks = profile.codeChecks
        // Release-style runtime by default, as upstream Madeira's bridge does:
        // no PC sampler suspending the game thread ~500 times a second, no
        // thread-suspending profilers, no per-present log lines, no 256 MB
        // JIT dump on a crash, and Mono logs at warning level. Settings ›
        // Bugs & logs › Detailed diagnostics turns them back on.
        if UserDefaults.standard.bool(forKey: "diagnostics.detailed") {
            for key in ["MADEIRA_QUIET", "MADEIRA_LEAN_DIAG"] { unsetenv(key) }
            setenv("MADEIRA_JIT_DUMP", "1", 1)
        } else {
            setenv("MADEIRA_QUIET", "1", 1)
            setenv("MADEIRA_LEAN_DIAG", "1", 1)
            setenv("MADEIRA_JIT_DUMP", "0", 1)
        }
        setenv("MONO_LOG_LEVEL", "warning", 0)
        sessionVulkanMode = profile.vulkanMode
        sessionOpenGLBackend = profile.openGLBackend
        setenv("IDECK_DISPLAY_SCALING", RuntimeConfiguration.SurfaceMode(saved: profile.surfaceScaling).rawValue, 1)
        setenv("IDECK_TOUCH_CONTROLS_ACTIVE", profile.touchControlPreset == "off" ? "0" : "1", 1)
        let controllerMode = profile.controllerAPI == "Automatic"
            ? (UserDefaults.standard.string(forKey: "wineControllerAPI") ?? "XInput")
            : profile.controllerAPI
        switch controllerMode {
        case "HID": setenv("MADEIRA_PAD_MODE", "hid", 1)
        case "DualSense HID": setenv("MADEIRA_PAD_MODE", "dualsense", 1)
        case "Generic HID": setenv("MADEIRA_PAD_MODE", "generic", 1)
        default: setenv("MADEIRA_PAD_MODE", "xinput", 1)
        }
        if controllerMode == "XInput + DirectInput" {
            setenv("MADEIRA_DINPUT_PAD", "1", 1)
        } else {
            unsetenv("MADEIRA_DINPUT_PAD")
        }
        // Avoid carrying the previous game's HID identity into this launch.
        unsetenv("MADEIRA_HIDPAD")
        unsetenv("MADEIRA_HIDPAD_NAME")
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

        let screen = UIScreen.main.nativeBounds.size
        sessionMetalFXFactor = profile.metalFXEnabled
            ? Self.metalFXFactor(resolution: profile.resolution, screenLongSide: max(screen.width, screen.height))
            : nil
        if let factor = sessionMetalFXFactor {
            // DXMT only builds its MetalFX swapchain when this is set.
            setenv("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1", 1)
            SteamLog.event(String(format: "[wine-launch] MetalFX spatial upscaling %.2fx", factor))
        } else {
            unsetenv("DXMT_METALFX_SPATIAL_SWAPCHAIN")
            if profile.metalFXEnabled {
                SteamLog.event("[wine-launch] MetalFX skipped: the game already renders at the screen's resolution")
            }
        }

        sessionGraphicsAPI = WindowsGameProfile.normalizedGraphicsAPI(profile.graphicsAPI)
        setenv("IDECK_FPS_LIMIT", profile.fpsLimit, 1)
        let limit = profile.fpsLimit == "Uncapped" ? 0 : RuntimeConfiguration.settings(for: profile).framesPerSecond
        let managed: Set<String> = ["d3d11.preferredMaxFrameRate", "d3d11.metalSpatialUpscaleFactor"]
        let existing = getenv("DXMT_CONFIG").map { String(cString: $0) } ?? ""
        var options = existing.split(separator: ";").map(String.init).filter {
            !managed.contains($0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        options.append("d3d11.preferredMaxFrameRate = \(limit)")
        if let factor = sessionMetalFXFactor {
            options.append(String(format: "d3d11.metalSpatialUpscaleFactor = %.2f", factor))
        }
        setenv("DXMT_CONFIG", options.joined(separator: ";"), 1)
    }

    /// How much MetalFX should enlarge a game rendering at `resolution` to fill
    /// a screen whose long side is `screenLongSide` pixels. DXMT and
    /// madeira-d3d12 accept 1 to 2; below 1.1 upscaling only costs GPU time,
    /// so it is off (nil), as it is for "Device native".
    static func metalFXFactor(resolution: String, screenLongSide: CGFloat) -> Double? {
        let parts = resolution.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0, screenLongSide > 0 else { return nil }
        let factor = min(Double(screenLongSide) / max(width, height), 2.0)
        return factor >= 1.1 ? (factor * 100).rounded(.down) / 100 : nil
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
