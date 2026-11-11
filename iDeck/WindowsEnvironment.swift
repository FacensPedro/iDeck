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
    private var sessionD3D12Renderer = "Madeira D3D12"
    private var sessionUseRecommended = true
    private var sessionCodeChecks = "Automatic"
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
            "arm64ec-windows/cmd.exe",
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
            MadeiraRuntime.exists($0)
        }) else { return false }
        // Wine's ntdll reads these three NLS files before anything else; without
        // them the wineserver dies at start. Never start Wine without them.
        guard MadeiraRuntime.missingNLSFiles().isEmpty, MadeiraRuntime.installedProblems().isEmpty else { return false }
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
            NativeSymbol.address(name) != nil
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
            let file = MadeiraRuntime.file(name)
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
            "arm64ec-windows/cmd.exe": "Wine Windows command interpreter",
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
            if !MadeiraRuntime.exists(relativePath) {
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
            if NativeSymbol.address(name) == nil {
                missing.append(label)
            }
        }
        if !native.metal_available { missing.append("Metal device") }
        for name in MadeiraRuntime.missingNLSFiles() {
            missing.append("Wine NLS file \(name) in \(MadeiraRuntime.resourceRoot.path)")
        }
        missing += MadeiraRuntime.installedProblems()
        return missing
    }

    func configureWine(prefix: String) {
        self.winePrefixPath = prefix
        setenv("WINEPREFIX", prefix, 1)
        if ProcessInfo.processInfo.environment["IDECK_WINE_DIAGNOSTICS"] == "1" ||
           UserDefaults.standard.bool(forKey: "diagnostics.detailed") {
            // Madeira's Wine process thread configures WINEDEBUG itself.
            // Use its supported flag to request detailed native traces.
            setenv("MADEIRA_DEBUG_VERBOSE", "1", 1)
            setenv("WINEDEBUG", "err+all", 1)
        } else {
            // Lean default: only exceptions (seh) and process errors, which the
            // bug report diagnoses crashes from. err+all wrote thousands of
            // lines per launch (thread, module, sync...), costing CPU and disk
            // while the game started.
            unsetenv("MADEIRA_DEBUG_VERBOSE")
            setenv("WINEDEBUG", "-all,err+seh,err+process", 1)
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
    
    static func isPE32WindowsExecutable(_ url: URL) -> Bool {
        url.path.withCString { ideck_native_pe_machine($0) == 0x014c }
    }
    
    /// Wine sessions started in this app run (Madeira's LibraryModel.sessionsThisRun).
    /// A second one cannot start in the same process: the wineserver's permanent
    /// objects from the first session are still there and init_registry aborts on
    /// "\Registry". iDeck asks for a restart instead, as Madeira does.
    /// madeira.cfg env.MADEIRA_ONE_SESSION_PER_RUN = 0 lets the launch go ahead.
    static var sessionsThisRun = 0
    /// Why Madeira's StikJITHelper could not allocate the pool (its poolFailure).
    static var lastPoolFailure: String?
    static let sessionAlreadyRan = Int32(EALREADY)
    static var oneSessionPerRun: Bool { MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN") }

    func execute(binary: URL, arguments: String = "", is32Bit: Bool = false, isSteam: Bool = false,
                 steamAppID: UInt32? = nil, steamInstallDirectory: URL? = nil,
                 steamWorkingDirectory: URL? = nil,
                 jitEnabler: JITEnabler, completion: @escaping (Int) -> Void) {
        guard Self.sessionsThisRun == 0 || !Self.oneSessionPerRun else {
            SteamLog.event("[session-once] launch held: \(Self.sessionsThisRun) session(s) already ran in this app run")
            completion(Int(EALREADY))
            return
        }
        // Report precisely which preflight failed. Wine has not started at
        // this point, so a generic EINVAL concealed a missing or invalid
        // prefix command interpreter during Steam's one-time installs.
        guard FileManager.default.fileExists(atPath: binary.path) else {
            SteamLog.event("[wine-launch] executable missing: \(binary.lastPathComponent)")
            completion(Int(EINVAL))
            return
        }
        let actualMachine = binary.path.withCString { ideck_native_pe_machine($0) }
        guard actualMachine != 0 else {
            SteamLog.event("[wine-launch] executable is not a valid Windows PE: \(binary.lastPathComponent)")
            completion(Int(EINVAL))
            return
        }
        guard let parsedArguments = BoxTranslator.parseArguments(arguments) else {
            SteamLog.event("[wine-launch] malformed or oversized Windows launch arguments for \(binary.lastPathComponent)")
            completion(Int(EINVAL))
            return
        }

        // IMAGE_FILE_MACHINE_ARM64EC is 0xA641, not ARM64 (0xAA64).
        // Only the command interpreter staged in the prefix may use this
        // exception; the native launcher repeats the same path restriction.
        let shellPath = URL(fileURLWithPath: winePrefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/windows/system32/cmd.exe")
            .resolvingSymlinksInPath().standardizedFileURL.path
        let nativeShell = actualMachine == 0xA641 &&
            binary.resolvingSymlinksInPath().standardizedFileURL.path == shellPath
        guard actualMachine == 0x014c || actualMachine == 0x8664 || nativeShell else {
            SteamLog.event("[wine-launch] unsupported Windows PE machine \(String(format: "0x%04x", actualMachine)) for \(binary.lastPathComponent)")
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
        // iDeck: the JIT pool list matches games by program name too.
        if binary.lastPathComponent.lowercased() != "dockhost.exe" && binary.lastPathComponent.lowercased() != "cmd.exe" {
            setenv("IDECK_JIT_GAME_EXE", binary.lastPathComponent, 1)
            if let steamAppID { setenv("IDECK_JIT_GAME_STEAM", String(steamAppID), 1) } else { unsetenv("IDECK_JIT_GAME_STEAM") }
        }
        writeSessionGraphicsConfig(binary: binary, is32Bit: needsWoW64,
                                   steamAppID: steamAppID, steamInstallDirectory: steamInstallDirectory)

        // The engine's own switch for the game's API preference goes last,
        // after the game's and the user's arguments.
        let engineSwitch = prepareGraphicsAPI(binary: binary)
        let launchArguments = parsedArguments + engineSwitch.filter { !parsedArguments.contains($0) }
        let architectureTranslator = BoxTranslator()
        // As Madeira's launch: the JIT pool from StikJITHelper, exported, and the
        // debugger detached, before the wineserver and Wine start.
        DispatchQueue.global(qos: .userInitiated).async {
          if let failure = MadeiraWinePool.prepare() {
            Self.lastPoolFailure = failure
            SteamLog.event("[wine-launch] JIT pool: " + failure)
            DispatchQueue.main.async { completion(Int(ENOMEM)) }
            return
          }
          DispatchQueue.main.async {
        architectureTranslator.translateAndRun(
            executablePath: binary.path,
            arguments: launchArguments,
            environment: self.winePrefixPath,
            is32Bit: needsWoW64,
            isSteam: isSteam,
            steamAppID: steamAppID,
            steamInstallDirectory: steamInstallDirectory,
            steamWorkingDirectory: steamWorkingDirectory,
            jitEnabler: jitEnabler
        ) { status in
            if status != 0 { SteamLog.event("[wine-launch] native launch failure code=\(status)") }
            else { Self.sessionsThisRun += 1 }
            completion(status)
        }
          }
        }
    }

    /// Whether this IPA carries Madeira's OpenGL/Vulkan runtime (gl/ and vulkan/).
    static var hasGLVulkanRuntime: Bool {
        ["gl/libMoltenVK.dylib", "vulkan/arm64ec-windows/winevulkan.dll",
         "vulkan/arm64ec-windows/vulkan-1.dll"].allSatisfy(MadeiraRuntime.exists)
    }

    /// Whether this IPA carries vkd3d-proton (build/vkd3d-proton/build.sh output).
    static var hasVKD3DProton: Bool {
        hasGLVulkanRuntime && ["vulkan/arm64ec-windows/d3d12.dll", "vulkan/arm64ec-windows/d3d12core.dll"].allSatisfy(MadeiraRuntime.exists)
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
        // Automatic choice, per game. Wine loads whichever Direct3D the game
        // calls, so only a game able to use both has a choice to make:
        // it keeps its own choice when this IPA runs both, and is switched to
        // Direct3D 11 (DXMT) through its engine when this IPA has no D3D12.
        guard d3d11 && d3d12 else {
            SteamLog.event("[graphics] automatic: \(d3d12 ? "Direct3D 12 (Madeira)" : d3d11 ? "Direct3D 11 (DXMT)" : "no Direct3D")")
            return []
        }
        guard !d3d12Available else {
            SteamLog.event("[graphics] automatic: the game chooses between Direct3D 11 and 12; both are available")
            return []
        }
        guard let argument = Self.engineAPIArgument(binary: binary, preferD3D12: false) else {
            AppLog.record("[graphics] \(binary.lastPathComponent) can use Direct3D 12, which this IPA cannot run, "
                          + "and has no known engine switch (Unity or Unreal) to select Direct3D 11.")
            return []
        }
        SteamLog.event("[graphics] automatic: Direct3D 11 (DXMT), passing \(argument): this IPA has no Direct3D 12")
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
        // As Madeira: `d3d12 = vkd3d` links vkd3d-proton's d3d12.dll and
        // d3d12core.dll over madeira-d3d12 for this session and turns on Vulkan
        // (MoltenVK). vkd3d-proton is ARM64EC, so 64-bit games only.
        if sessionD3D12Renderer == "VKD3D-Proton" {
            if Self.hasVKD3DProton && !is32Bit {
                lines.append("d3d12 = vkd3d")
            } else {
                SteamLog.event("[wine-launch] VKD3D-Proton chosen but \(is32Bit ? "the game is 32-bit" : "not in this build"); madeira-d3d12 used")
            }
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
        // Lighter sessions for heavy games (Madeira's own switches):
        // quiet-log drops the Direct3D 12 census frames and OutputDebugString
        // per log line (each froze the game 1-2 s / cost ~0.5 ms); ring-share
        // returns argument-buffer memory as soon as the GPU is done with it
        // (RDR2 kept 1.5 GB with it off).
        lines.append("quiet-log = 1")
        lines.append("ring-share = 1")
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
        // As Madeira (DockInstallers.applyInstallSessionConfig): a session of
        // one-time installs leaves out the game's address-space layout lines.
        // MADEIRA_DOCK_INSTALL_LAYOUT = 0 keeps every line.
        if getenv("MADEIRA_DOCK_INSTALLS_SESSION").map({ String(cString: $0) }) == "1",
           MadeiraConfig.flag("MADEIRA_DOCK_INSTALL_LAYOUT") {
            let before = lines.count
            lines.removeAll { line in
                let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return DockInstallers.installSessionDroppedKeys.contains(key)
            }
            if lines.count != before { SteamLog.event("[dock-installers] install session leaves out \(before - lines.count) layout line(s)") }
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

    /// Madeira's per-launch environment (LibraryEntry.applyEnvironment, line by
    /// line), with the defaults of the per-game choices iDeck does not offer:
    /// set or unset every time, so one game's value never leaks into the next.
    /// Keys madeira.cfg sets still apply (WineProcessBridge's ml1184 rules).
    private func applyMadeiraLaunchEnvironment(_ profile: WindowsGameProfile) {
        unsetenv("MADEIRA_GDI_SHARED_SECTION")   // a Dock launch sets it again
        unsetenv("MADEIRA_MADSYNC_SESSION")      // an installer session sets it again
        unsetenv("MADEIRA_DOCK_INSTALLS_SESSION")
        setenv("FEX_X87REDUCEDPRECISION", profile.reducedX87 ? "1" : "0", 1)
        if (1..<64).contains(profile.cpuCount) { setenv("MADEIRA_CPU_COUNT", String(profile.cpuCount), 1) }
        else { unsetenv("MADEIRA_CPU_COUNT") }
        if [1, 2, 4, 8].contains(profile.anisotropyLimit) { setenv("DXMT_D9_ANISO_LIMIT", String(profile.anisotropyLimit), 1) }
        else { unsetenv("DXMT_D9_ANISO_LIMIT") }
        if profile.frameGeneration { setenv("MADEIRA_FRAMEGEN", "1", 1) } else { unsetenv("MADEIRA_FRAMEGEN") }
        if profile.reportNVIDIA { setenv("DXMT_ENABLE_NVEXT", "1", 1) } else { unsetenv("DXMT_ENABLE_NVEXT") }
        // Every game: DXGI lists the same monitor and display modes as
        // user32 (win32u's mode table). DXGI's own three-mode list disagreed
        // with EnumDisplaySettings, and games that match the two found an
        // empty list: Crash Bandicoot N. Sane Trilogy read the last entry of
        // it and stopped right after loading its shaders.
        setenv("DXMT_WSI_MONITOR_IDENTITY", "1", 1)
        setenv("DXMT_WSI_MODE_TABLE", "1", 1)
        // Fastsync's per-game switches, only when Settings chose Fastsync.
        if MadeiraSyncEngine.current == .fastsync {
            let mode = MadeiraConfig.get("env.MADEIRA_FASTSYNC") ?? "auto"
            setenv("MADEIRA_FASTSYNC", profile.fastSync ? mode : "0", 1)
            unsetenv("MADEIRA_FASTSYNC_SEM")
        } else {
            unsetenv("MADEIRA_FASTSYNC")
        }
    }

    func applyGameProfile(_ profile: WindowsGameProfile) {
        applyMadeiraLaunchEnvironment(profile)
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
        sessionD3D12Renderer = profile.d3d12Renderer
        sessionOpenGLBackend = profile.openGLBackend
        setenv("IDECK_DISPLAY_SCALING", RuntimeConfiguration.SurfaceMode(saved: profile.surfaceScaling).rawValue, 1)
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
        // The game's screen: the active window scene's (UIScreen.main is deprecated).
        // Off the main thread the size last read on it: a fixed 12.9-inch
        // iPad Pro size made MetalFX scale to the wrong size and, at "Device
        // native", render a 4:3 picture on every other screen shape.
        let screen: CGSize = Thread.isMainThread
            ? MainActor.assumeIsolated { Self.readScreenPixels() }
            : Self.screenPixels
        // MetalFX at "Device native": the game renders at 2/3 of the screen
        // and MetalFX enlarges it 1.5x, about 55% fewer pixels for the GPU to
        // shade with little visible loss.
        let resolution = Self.renderResolution(profile.resolution, metalFX: profile.metalFXEnabled, screen: screen)
        if resolution == "Device native" {
            unsetenv("MADEIRA_SCREEN_W")
            unsetenv("MADEIRA_SCREEN_H")
            unsetenv("MADEIRA_SCREEN_SRC")
        } else {
            let parts = resolution.split(separator: "x")
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

        // AVX/AVX2 translation: when a game's recommendation asks for it, or
        // automatically after the game stopped on an AVX instruction (AVXAuto).
        if profile.avxEnabled || AVXAuto.isOn(profile.id) {
            setenv("MADEIRA_FEX_AVX", "1", 1)
        } else {
            unsetenv("MADEIRA_FEX_AVX")
        }

        sessionMetalFXFactor = profile.metalFXEnabled
            ? Self.metalFXFactor(resolution: resolution, screenLongSide: max(screen.width, screen.height))
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

        setenv("IDECK_FPS_LIMIT", profile.fpsLimit, 1)
        Self.applyFrameRateLimit(profile.fpsLimit)
        // "Auto": Madeira's frame-cap governor holds the CPU near 1.5 W by
        // moving the cap between 60 and 20 fps (read at session start).
        if profile.fpsLimit == "Auto" {
            setenv("MADEIRA_FPS_GOV_MW", "1500", 1)
        } else {
            unsetenv("MADEIRA_FPS_GOV_MW")
        }
        let limit = profile.fpsLimit == "Uncapped" ? 0
            : profile.fpsLimit == "Auto" ? 60 : RuntimeConfiguration.settings(for: profile).framesPerSecond
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

    /// DXMT's present mode on iOS (madeira_set_vsync_locked): 1 = 60, 3 = 30,
    /// 4 = 40, 0 = the display's maximum. This is the cap that works: DXMT's
    /// d3d11.preferredMaxFrameRate is ignored on iOS (its present path drops
    /// the minimum duration), so a 30 FPS limit used to run at 60.
    static func vsyncMode(for fpsLimit: String) -> Int32 {
        switch fpsLimit {
        case "30": return 3
        case "40": return 4
        case "Uncapped": return 0
        default: return 1   // "60" and "Auto" (whose governor lowers it further)
        }
    }

    private static let screenLock = NSLock()
    private static var cachedScreenPixels: CGSize?

    /// The active scene's screen in pixels, as last read on the main thread.
    static var screenPixels: CGSize {
        screenLock.lock(); defer { screenLock.unlock() }
        return cachedScreenPixels ?? CGSize(width: 2732, height: 2048)
    }

    /// Reads (and remembers) the active scene's screen size in pixels.
    @MainActor @discardableResult static func readScreenPixels() -> CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let size = active?.screen.nativeBounds.size, size.width > 0, size.height > 0 else { return screenPixels }
        screenLock.lock(); cachedScreenPixels = size; screenLock.unlock()
        return size
    }

    private typealias SetVsyncMode = @convention(c) (Int32) -> Void

    /// Applies an FPS limit at once, also while a game runs (it is read on
    /// every present).
    static func applyFrameRateLimit(_ fpsLimit: String) {
        let mode = vsyncMode(for: fpsLimit)
        guard let symbol = NativeSymbol.address("madeira_set_vsync_locked") else {
            SteamLog.event("[fps] madeira_set_vsync_locked is not linked; limit \(fpsLimit) not applied")
            return
        }
        unsafeBitCast(symbol, to: SetVsyncMode.self)(mode)
        SteamLog.event("[fps] limit \(fpsLimit) -> present mode \(mode)")
    }

    /// The resolution the game renders at: "Device native" with MetalFX on
    /// becomes 2/3 of the screen (landscape, even sizes), for MetalFX to enlarge.
    static func renderResolution(_ resolution: String, metalFX: Bool, screen: CGSize) -> String {
        guard metalFX, resolution == "Device native", screen.width > 0, screen.height > 0 else { return resolution }
        let long = max(screen.width, screen.height), short = min(screen.width, screen.height)
        let width = Int(long * 2 / 3) & ~1, height = Int(short * 2 / 3) & ~1
        guard (320...7680).contains(width), (240...4320).contains(height) else { return resolution }
        return "\(width)x\(height)"
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
        guard let symbol = NativeSymbol.address("ideck_madeira_launch_v1"),
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


/// Where the last unhandled illegal instruction (0xC000001D) of a session was
/// raised, read from Wine's log. Guest code (the game, x86 or x64) runs at the
/// Windows addresses the runtime maps from 0x70_0000_0000 up; an address below
/// that is the runtime's own native code, which AVX translation cannot affect.
enum IllegalInstructionOrigin {
    static let guestBase: UInt64 = 0x70_0000_0000
    private static let marker = "Unhandled exception code c000001d"

    /// The address on the last "Unhandled exception code c000001d ... addr 0x..." line.
    static func lastAddress(in log: String) -> UInt64? {
        guard let line = log.components(separatedBy: "\n").last(where: { $0.contains(marker) }),
              let range = line.range(of: " addr 0x") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isHexDigit }
        return UInt64(digits, radix: 16)
    }

    static func isHost(address: UInt64) -> Bool { address < guestBase }

    /// True only when the log names an address and it is the runtime's own.
    static func isHost(logURL: URL?, since offset: Int64?) -> Bool {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return false }
        defer { try? handle.close() }
        if let offset, offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        guard let data = try? handle.readToEnd(),
              let address = lastAddress(in: String(decoding: data, as: UTF8.self)) else { return false }
        return isHost(address: address)
    }
}

/// Games that need AVX/AVX2 translation, found when one stops on an illegal
/// instruction (0xC000001D); kept per game, by its profile ID.
enum AVXAuto {
    private static let key = "avxAutoGames"

    static func isOn(_ game: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(game)
    }

    /// True when it was off before.
    @discardableResult
    static func enable(_ game: String) -> Bool {
        var games = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !games.contains(game) else { return false }
        games.append(game)
        UserDefaults.standard.set(games, forKey: key)
        AppLog.record("[avx] \(game) stopped on an illegal instruction: AVX/AVX2 translation on for it")
        return true
    }
}


