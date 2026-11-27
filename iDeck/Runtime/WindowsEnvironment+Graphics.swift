// WindowsEnvironment: graphics APIs and the session's graphics config.
// Split from WindowsEnvironment.swift (iDeck 3.0 architecture).

import Foundation
import Darwin
import UIKit

extension WindowsEnvironment {
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

    /// OpenGL games whose renderer needs a desktop OpenGL version this runtime does not
    /// offer (Zink on MoltenVK stops short of OpenGL 4.5 core) and that ship their own
    /// Vulkan build next to the OpenGL one. DOOM (2016) asks for a 4.5 core context and
    /// stops with "wglCreateContextAttribsARB failed"; DOOMx64vk.exe runs on MoltenVK.
    static let vulkanBuilds: [String: String] = ["doomx64.exe": "DOOMx64vk.exe"]

    /// The game's Vulkan executable to launch instead of `binary`, or nil.
    static func vulkanBuild(of binary: URL, vulkanMode: String, runtime: Bool) -> URL? {
        guard vulkanMode != "Off", runtime,
              let name = vulkanBuilds[binary.lastPathComponent.lowercased()] else { return nil }
        let candidate = binary.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
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
    func prepareGraphicsAPI(binary: URL) -> [String] {
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
            SteamLog.event("[graphics] automatic: \(d3d12 ? "Direct3D 12 (Madeira)" : d3d11 ? "Direct3D 11 (DXMT)" : "no D3D11 or D3D12 import detected; runtime selection remains automatic")")
            return []
        }
        guard !d3d12Available else {
            // A game whose Direct3D 12 session failed (a crash, GPU errors) and that has
            // an engine switch runs on Direct3D 11 (DXMT) from then on.
            if D3D12Fallback.isOn(binary), let argument = Self.engineAPIArgument(binary: binary, preferD3D12: false) {
                SteamLog.event("[graphics] automatic: Direct3D 11 (DXMT), passing \(argument): its Direct3D 12 session failed before")
                return [argument]
            }
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
    /// The executable window the game needs (StikJITHelper.exeWindowAutoMB, read once
    /// by the next pool allocation). Steam games are measured in their install folder,
    /// since the program started is Madeira Dock's host; others in the program's folder.
    static func measureExecutableWindow(binary: URL, steamInstallDirectory: URL?) {
        let name = binary.lastPathComponent.lowercased()
        let folder = steamInstallDirectory ?? (name == "dockhost.exe" || name == "cmd.exe" ? nil : binary.deletingLastPathComponent())
        guard let folder, let need = StikJITHelper.fixedBaseWindowMB(in: folder) else {
            StikJITHelper.exeWindowAutoMB = 0
            return
        }
        StikJITHelper.exeWindowAutoMB = need.mb
        if ideck_wine_jit_pool_ready(), SystemCoordinator.earlyPoolExeWindowMB > 0,
           need.mb > SystemCoordinator.earlyPoolExeWindowMB {
            AppLog.record("[exe-window] \(need.exe) needs \(need.mb) MB but the JIT pool prepared at startup "
                + "kept \(SystemCoordinator.earlyPoolExeWindowMB) MB free: the game may fail to load "
                + "(c0000018). Set exe-window-mb in its config, then reopen iDeck through StikDebug.")
        }
        LogStore.shared.log("[exe-window] \(need.exe) is a fixed-base image ending \(need.mb)MB above 0x140000000: "
            + "the executable window is widened to \(need.mb)MB for this session (exe-window-mb in the game's file overrides)")
    }

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
    func writeSessionGraphicsConfig(binary: URL, is32Bit: Bool,
                                            steamAppID: UInt32? = nil, steamInstallDirectory: URL? = nil) {
        var lines = ["# Written by iDeck for this launch: \(binary.lastPathComponent)"]
        if sessionUseRecommended {
            let recommendation = Self.recommendation(binary: binary, steamAppID: steamAppID,
                                                     steamInstallDirectory: steamInstallDirectory)
            lines += recommendation.config.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            SteamLog.event("[wine-launch] recommended settings: \(recommendation.id) v\(recommendation.version)")
            Self.setD3D9OlderNvidia(recommendation.olderNvidia == true)
        } else {
            Self.setD3D9OlderNvidia(false)
        }
        lines += VirtualSwap.configLines(existing: lines)
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
        // The game's own JIT pool size (its page, Performance): MadeiraWinePool.sizeMB
        // reads `pool` from this per-game config before Settings. A pool prepared
        // at startup keeps its size for this run.
        if sessionJITPoolMiB > 0 {
            lines.append("pool = \(sessionJITPoolMiB)")
            if ideck_wine_jit_pool_ready() {
                AppLog.record("[jit] this game asks for a \(sessionJITPoolMiB) MB pool; the pool prepared at startup is kept until iDeck is reopened")
            }
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

    static func turnOffFirefoxSandbox(binary: URL) {
        for name in mozillaSandboxSwitches { setenv(name, "1", 1) }
        let folder = binary.deletingLastPathComponent()
        let fm = FileManager.default
        // Tor Browser: Browser/firefox.exe, started directly or by "Start Tor Browser.exe".
        let browser = [folder, folder.appendingPathComponent("Browser")]
            .first { fm.fileExists(atPath: $0.appendingPathComponent("firefox.exe").path) }
        guard let browser else { return }
        let tor = browser.appendingPathComponent("TorBrowser")
        guard fm.fileExists(atPath: tor.path) else { return }
        // The profile may not exist before the first start: Firefox fills the folder in.
        let profiles = [tor.appendingPathComponent("Data/Browser/profile.default")]
        for profile in profiles {
            try? fm.createDirectory(at: profile, withIntermediateDirectories: true)
            let userJS = profile.appendingPathComponent("user.js")
            var text = (try? String(contentsOf: userJS, encoding: .utf8)) ?? ""
            guard !text.contains(firefoxUserJSMarker) else { continue }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += firefoxUserJS + "\n"
            do {
                try text.write(to: userJS, atomically: true, encoding: .utf8)
                SteamLog.event("[firefox] sandbox turned off in the Tor Browser profile (user.js)")
            } catch {
                SteamLog.event("[firefox] could not write user.js: \(error.localizedDescription)")
            }
        }
    }
}

/// Games able to use Direct3D 11 and 12 whose Direct3D 12 session (madeira-d3d12)
/// failed: their engine switch selects Direct3D 11 (DXMT) at every later launch. Kept by
/// program path (the last 64), in UserDefaults under `key`.
enum D3D12Fallback {
    static let key = "graphics.d3d12Fallback.v1"
    /// The Wine log line of a session that loaded Direct3D 12 (trace+loaddll), lower-cased.
    static let loadedMarker = "d3d12.dll\" at"

    static func isOn(_ binary: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(binary.path)
    }

    /// After a failed session: records the program when it can use both APIs, ran on
    /// Direct3D 12 and has a switch to leave it. Returns whether it was recorded now.
    @discardableResult
    static func note(_ binary: URL, loadedD3D12: Bool) -> Bool {
        guard loadedD3D12, !isOn(binary) else { return false }
        let bits = WindowsEnvironment.graphicsAPIs(of: binary)
        guard bits & UInt32(IDECK_API_D3D11) != 0, bits & UInt32(IDECK_API_D3D12) != 0,
              WindowsEnvironment.engineAPIArgument(binary: binary, preferD3D12: false) != nil else { return false }
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.append(binary.path)
        UserDefaults.standard.set(Array(list.suffix(64)), forKey: key)
        SteamLog.event("[graphics] \(binary.lastPathComponent): its Direct3D 12 session failed; Direct3D 11 (DXMT) from the next launch")
        return true
    }
}
