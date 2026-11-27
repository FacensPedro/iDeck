import Foundation
import Darwin
import UIKit

class WindowsEnvironment {
    var winePrefixPath: String = ""
    var steamRegistryInitializedPrefixes = Set<String>()
    let graphicsConfig = GraphicsConfig()
    let audioManager = AudioManager()
    let steamManager = SteamManager()
    /// The profile's Vulkan/OpenGL choices, applied when the executable is known.
    var sessionVulkanMode = "Automatic"
    var sessionD3D12Renderer = "Madeira D3D12"
    var sessionUseRecommended = true
    var sessionCodeChecks = "Automatic"
    var sessionJITPoolMiB = 0
    var sessionOpenGLBackend = "Automatic"
    /// MetalFX spatial upscale factor for this launch (nil = off).
    var sessionMetalFXFactor: Double?
    
    var nativeGraphicsBackend: String? {
        MadeiraBundleIdentity.nativeManifest?["graphicsBackend"] as? String
    }

    /// Wine's log channels for every session (see configureWine).
    static let wineDebugChannels = "err+all,err-ole,err-winediag,fixme-all,warn-all,trace+process,trace+loaddll"

    
    
    
    /// Wine sessions started in this app run (Madeira's LibraryModel.sessionsThisRun).
    /// A second one cannot start in the same process: the wineserver's permanent
    /// objects from the first session are still there and init_registry aborts on
    /// "\Registry". iDeck asks for a restart instead, as Madeira does.
    /// madeira.cfg env.MADEIRA_ONE_SESSION_PER_RUN = 0 lets the launch go ahead.
    static var sessionsThisRun = 0
    /// Why Madeira's StikJITHelper could not allocate the pool (its poolFailure).
    /// DXMT_MAX_FRAME_LATENCY was set by iDeck's low-memory rule (not a game config).
    static var lowMemoryFrameLatency = false
    static var lastPoolFailure: String?
    static let sessionAlreadyRan = Int32(EALREADY)
    static var oneSessionPerRun: Bool { MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN") }

    /// Bethesda's launchers and the game each one starts. The launcher only detects the
    /// video hardware, writes the graphics INI and then starts the game; under Wine it
    /// stopped at "Detecting Video Hardware" or closed on Play (Fallout: New Vegas from
    /// Epic). The games write their default INI themselves when it is missing.
    static let bethesdaLaunchers: [String: String] = [
        "falloutnvlauncher.exe": "FalloutNV.exe",
        "falloutlauncher.exe": "Fallout3.exe",
        "fallout3launcher.exe": "Fallout3.exe",
        "fallout4launcher.exe": "Fallout4.exe",
        "skyrimlauncher.exe": "TESV.exe",
        "skyrimselauncher.exe": "SkyrimSE.exe",
        "skyrimvrlauncher.exe": "SkyrimVR.exe",
        "oblivionlauncher.exe": "Oblivion.exe",
        "morrowind launcher.exe": "Morrowind.exe",
    ]

    /// The game's own executable next to a Bethesda launcher, or nil.
    static func bethesdaGameExecutable(for launcher: URL) -> URL? {
        guard let name = bethesdaLaunchers[launcher.lastPathComponent.lowercased()] else { return nil }
        let folder = launcher.deletingLastPathComponent()
        let exact = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        // Windows names are case-insensitive; the files on APFS may differ in case.
        let match = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .first { $0.lowercased() == name.lowercased() }
        return match.map { folder.appendingPathComponent($0) }
    }

    func execute(binary requestedBinary: URL, arguments: String = "", is32Bit: Bool = false, isSteam: Bool = false,
                 steamAppID: UInt32? = nil, steamInstallDirectory: URL? = nil,
                 steamWorkingDirectory: URL? = nil,
                 jitEnabler: JITEnabler, completion: @escaping (Int) -> Void) {
        let vulkanBuild = Self.vulkanBuild(of: requestedBinary, vulkanMode: sessionVulkanMode, runtime: Self.hasGLVulkanRuntime)
        if let vulkanBuild {
            SteamLog.event("[graphics] \(requestedBinary.lastPathComponent) needs OpenGL 4.5 core, past this runtime: launching its Vulkan build \(vulkanBuild.lastPathComponent)")
        }
        let vulkanOrRequested = vulkanBuild ?? requestedBinary
        let bethesdaGame = Self.bethesdaGameExecutable(for: vulkanOrRequested)
        if let bethesdaGame {
            SteamLog.event("[launch] Bethesda launcher \(vulkanOrRequested.lastPathComponent) skipped: starting \(bethesdaGame.lastPathComponent) directly")
        }
        let binary = bethesdaGame ?? vulkanOrRequested
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
        Self.turnOffFirefoxSandbox(binary: binary)
        writeSessionGraphicsConfig(binary: binary, is32Bit: needsWoW64,
                                   steamAppID: steamAppID, steamInstallDirectory: steamInstallDirectory)

        // The engine's own switch for the game's API preference goes last,
        // after the game's and the user's arguments.
        let engineSwitch = prepareGraphicsAPI(binary: binary)
        // DLLs the program needs that Wine will not find, or built for another
        // architecture: logged now, added to the reason if the session ends early.
        DependencyCheck.last = nil
        if let check = DependencyCheck.run(program: binary, prefix: MadeiraDock.prefix) {
            // iDeck Auto DLL Manager: missing DLLs from their official source, cached.
            AutoDLLManager.resolve(check, program: binary, prefix: MadeiraDock.prefix)
        }
        let launchArguments = parsedArguments + engineSwitch.filter { !parsedArguments.contains($0) }
        let architectureTranslator = BoxTranslator()
        // As Madeira's launch: the JIT pool from StikJITHelper, exported, and the
        // debugger detached, before the wineserver and Wine start.
        DispatchQueue.global(qos: .userInitiated).async {
          // As Madeira's Dock launch (ContentView): measure the game's own fixed-base
          // exe first, so the pool is placed above it. iDeck never did, so a 64-bit
          // exe without relocations that is larger than the 128MB executable window
          // (Assassin's Creed Unity's ACU.exe, 131MB) found the pool on top of it and
          // failed with "failed to create main module ... c0000018".
          Self.measureExecutableWindow(binary: binary, steamInstallDirectory: steamInstallDirectory)
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

    /// Firefox's sandbox (Tor Browser, Firefox, Waterfox, LibreWolf) cannot work under
    /// Wine on iOS: its broker writes into the child processes and starts them with a
    /// restricted token, and Wine refuses both (NtWriteVirtualMemory and
    /// NtCreateUserProcess return c0000022), so tabs, the GPU process and tor's helpers
    /// never start. Every launch gets Mozilla's switches that turn the sandboxes off
    /// (they do nothing for other programs), and a Firefox profile next to the program
    /// gets a user.js with the same choice and fewer helper processes.
    static let mozillaSandboxSwitches = [
        "MOZ_DISABLE_CONTENT_SANDBOX", "MOZ_DISABLE_GPU_SANDBOX", "MOZ_DISABLE_RDD_SANDBOX",
        "MOZ_DISABLE_SOCKET_PROCESS_SANDBOX", "MOZ_DISABLE_UTILITY_SANDBOX", "MOZ_DISABLE_GMP_SANDBOX",
        "MOZ_DISABLE_VR_SANDBOX",
    ]
    static let firefoxUserJSMarker = "// iDeck: Firefox sandbox off under Wine"
    static let firefoxUserJS = [
        firefoxUserJSMarker,
        "user_pref(\"security.sandbox.content.level\", 0);",
        "user_pref(\"security.sandbox.gpu.level\", 0);",
        "user_pref(\"security.sandbox.rdd.level\", 0);",
        "user_pref(\"security.sandbox.socket.process.level\", 0);",
        "user_pref(\"security.sandbox.utility.level\", 0);",
        "user_pref(\"browser.launcherProcess.enabled\", false);",
        "user_pref(\"layers.gpu-process.enabled\", false);",
        "user_pref(\"media.rdd-process.enabled\", false);",
        "user_pref(\"network.process.enabled\", false);",
        "user_pref(\"fission.autostart\", false);",
        "user_pref(\"dom.ipc.processCount\", 1);",
        "// iDeck: end",
    ].joined(separator: "\n")

    /// Madeira's per-launch environment (LibraryEntry.applyEnvironment, line by
    /// line), with the defaults of the per-game choices iDeck does not offer:
    /// set or unset every time, so one game's value never leaks into the next.
    /// Keys madeira.cfg sets still apply (WineProcessBridge's ml1184 rules).
    func applyMadeiraLaunchEnvironment(_ profile: WindowsGameProfile) {
        unsetenv("MADEIRA_GDI_SHARED_SECTION")   // a Dock launch sets it again
        unsetenv("MADEIRA_MADSYNC_SESSION")      // an installer session sets it again
        unsetenv("MADEIRA_DOCK_INSTALLS_SESSION")
        setenv("FEX_X87REDUCEDPRECISION", profile.reducedX87 ? "1" : "0", 1)
        if (1..<64).contains(profile.cpuCount) { setenv("MADEIRA_CPU_COUNT", String(profile.cpuCount), 1) }
        else { unsetenv("MADEIRA_CPU_COUNT") }
        if [1, 2, 4, 8].contains(profile.anisotropyLimit) { setenv("DXMT_D9_ANISO_LIMIT", String(profile.anisotropyLimit), 1) }
        else { unsetenv("DXMT_D9_ANISO_LIMIT") }
        // MetalFX (upscaling and frame generation) only on devices with 8 GB or more.
        if profile.frameGeneration && WindowsGameProfile.metalFXAllowed { setenv("MADEIRA_FRAMEGEN", "1", 1) } else { unsetenv("MADEIRA_FRAMEGEN") }
        if profile.reportNVIDIA { setenv("DXMT_ENABLE_NVEXT", "1", 1) } else { unsetenv("DXMT_ENABLE_NVEXT") }
        // Every game: DXGI lists the same monitor and display modes as
        // user32 (win32u's mode table). DXGI's own three-mode list disagreed
        // with EnumDisplaySettings, and games that match the two found an
        // empty list: Crash Bandicoot N. Sane Trilogy read the last entry of
        // it and stopped right after loading its shaders.
        setenv("DXMT_WSI_MONITOR_IDENTITY", "1", 1)
        setenv("DXMT_WSI_MODE_TABLE", "1", 1)
        // RAM: DXMT keeps a frame's staging buffers alive per frame in flight. With
        // less than 3 GB left for the game, one frame in flight instead of two
        // (a game's own DXMT_MAX_FRAME_LATENCY, from its config, still wins). The
        // shader cache on disk is capped at 128 MB (its SQLite file is mapped).
        if getenv("DXMT_MAX_FRAME_LATENCY") == nil || Self.lowMemoryFrameLatency {
            // Also after iOS stopped iDeck for memory while this game ran (MemoryGuard).
            let low = Int(os_proc_available_memory() >> 20) < 3072 || MemoryGuard.lighten(profile.id) || GPUFaultGuard.faulted(profile.id)
            Self.lowMemoryFrameLatency = low
            if low { setenv("DXMT_MAX_FRAME_LATENCY", "1", 1) } else { unsetenv("DXMT_MAX_FRAME_LATENCY") }
            AppLog.record("[memory] DXMT frames in flight: \(low ? 1 : 2) (\(Int(os_proc_available_memory() >> 20)) MiB left)")
        }
        // Reuse compiled Metal pipelines across launches when memory permits.
        if MadeiraConfig.get("env.DXMT_PIPELINE_ARCHIVE") == nil {
            setenv("DXMT_PIPELINE_ARCHIVE", os_proc_available_memory() >= 4096 * 1024 * 1024 ? "1" : "0", 1)
        }
        // The cap shrinks to 64 MB when storage is short (under 4 GB free) or the GPU
        // domain is on Economy: the cache only saves compile time, the space is the game's.
        if MadeiraConfig.get("env.DXMT_SHADER_CACHE_MAX_MB") == nil {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            let small = free < 4 << 30 || ResourceDomains.effective(.gpu) == .economy
            setenv("DXMT_SHADER_CACHE_MAX_MB", small ? "64" : "128", 1)
            if small { AppLog.record("[shaders] shader cache capped at 64 MB for this launch") }
        }
        // Fastsync's per-game switches, only when Settings chose Fastsync.
        if MadeiraSyncEngine.current == .fastsync {
            let mode = MadeiraConfig.get("env.MADEIRA_FASTSYNC") ?? "auto"
            setenv("MADEIRA_FASTSYNC", profile.fastSync ? mode : "0", 1)
            unsetenv("MADEIRA_FASTSYNC_SEM")
        } else {
            unsetenv("MADEIRA_FASTSYNC")
        }
    }

    /// The d3d9 options of "Older NVIDIA card (Direct3D 9)" (Madeira's D3D9Identity):
    /// a GeForce 7900 GS and its driver, for games that check the card. Removed again
    /// for a game that does not ask for it, since DXMT_CONFIG outlives the session.
    /// Written without spaces: DXMT reads at most 259 characters of DXMT_CONFIG.
    static let olderNvidiaD3D9: [String] = [
        "d3d9.customVendorId=10de", "d3d9.customDeviceId=0292",
        "d3d9.customDeviceDesc=\"NVIDIA GeForce 7900 GS\"", "d3d9.customDriver=nv4_disp.dll",
    ]

    static let screenLock = NSLock()
    static var cachedScreenPixels: CGSize?

    /// The active scene's screen in pixels, as last read on the main thread.
    static var screenPixels: CGSize {
        screenLock.lock(); defer { screenLock.unlock() }
        return cachedScreenPixels ?? CGSize(width: 2732, height: 2048)
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

