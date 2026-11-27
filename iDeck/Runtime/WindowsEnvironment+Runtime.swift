// WindowsEnvironment: the Windows runtime in the IPA and the prefix.
// Split from WindowsEnvironment.swift (iDeck 3.0 architecture).

import Foundation
import Darwin

extension WindowsEnvironment {
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
        // 2.13.1: MADEIRA_DEBUG_VERBOSE=1 made Madeira's Wine thread REPLACE the value
        // below with its verbose set (trace+syscall, trace+file, trace+module,
        // trace+win, fixme+all...): a 16 MB, 220,000-line madeira-log.txt for one
        // session, 82,000 of its lines NtFlushInstructionCache calls, too large to
        // read. Off, Madeira keeps this WINEDEBUG (madeira-wine-idle-logging.patch).
        setenv("MADEIRA_DEBUG_VERBOSE", "0", 1)
        // Errors from every channel, without the fixme/warn lines Wine repeats for
        // every call of an unimplemented function (thousands per minute in some games):
        // they fill madeira-log.txt and make each scan of it slower. A game's own
        // config (GameRecommendations, env.WINEDEBUG) still overrides this.
        // err:ole and err:winediag repeat harmless probing on every COM call and
        // Bugs & logs already ignores them: they are not written at all.
        // trace:process and trace:loaddll stay: Bugs & logs lists the programs a
        // session started (SessionProgramsTrace) and an EA game's activation from them.
        setenv("WINEDEBUG", Self.wineDebugChannels, 1)
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
}
