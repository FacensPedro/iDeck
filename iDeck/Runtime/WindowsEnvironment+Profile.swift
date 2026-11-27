// WindowsEnvironment: a game's profile as the session's environment.
// Split from WindowsEnvironment.swift (iDeck 3.0 architecture).

import Foundation
import Darwin
import UIKit

extension WindowsEnvironment {
    func applyGameProfile(_ profile: WindowsGameProfile) {
        applyMadeiraLaunchEnvironment(profile)
        Self.applyGameLanguage(profileID: profile.id)
        // A previous Madeira Dock launch leaves its host switches in the
        // process environment; only a new Dock launch sets them again.
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN",
                    "MADEIRA_STEAM_HOST_LAUNCH", "MADEIRA_STEAM_HOST_APPID", "MADEIRA_STEAM_HOST_LAUNCH_OPTION",
                    "MADEIRA_STEAM_HOST_CLIENT_DIR", "MADEIRA_STEAM_HOST_EXPECTED_INSTALL", "MADEIRA_STEAM_HOST_LOG",
                    "MADEIRA_STEAM_HOST_ARGUMENTS", "MADEIRA_STEAM_HOST_CEG", "MADEIRA_JIT_IMAGE_RETIRE",
                    "MADEIRA_IMAGE_MAP_GUARD", "MADEIRA_DOCK_AUTH_FILE", "MADEIRA_DOCK_OFFLINE"] {
            unsetenv(key)
        }
        // An EA game whose last session opened EA's activation window: one launch with
        // Wine's file, registry and module traces, so the log shows what the activation
        // library reads between "License signature is good" and that window (its own
        // log names no reason). The next launch is back to the usual channels.
        let traceKey = "ea.traceActivation." + profile.id
        if profile.id.hasPrefix("ea:"), UserDefaults.standard.bool(forKey: traceKey) {
            UserDefaults.standard.removeObject(forKey: traceKey)
            setenv("WINEDEBUG", Self.wineDebugChannels + ",trace+file,trace+reg,trace+module", 1)
            SteamLog.event("[ea-license] \(profile.id): this launch traces files, registry and modules for the activation")
        } else {
            setenv("WINEDEBUG", Self.wineDebugChannels, 1)
        }
        sessionUseRecommended = profile.useRecommended
        sessionCodeChecks = profile.codeChecks
        // Full code checks after a session of this game ended in FEX's self-modifying
        // code loop (FullCodeChecksAuto), unless the game's page chose a mode.
        if sessionCodeChecks == "Automatic", FullCodeChecksAuto.isOn(profile.id) {
            sessionCodeChecks = "Compatible"
            SteamLog.event("[wine-launch] full code checks: a session of this game looped on self-modifying code")
        }
        UserDefaults.standard.set(profile.id, forKey: FullCodeChecksAuto.lastGameKey)
        sessionJITPoolMiB = profile.jitPoolMiB
        // Detailed logs without the tools that slow a game. MADEIRA_QUIET keeps the
        // PC sampler (it suspends the game thread ~500 times a second) and the
        // per-present lines off; Wine's ERR lines and boot logging are not affected by
        // it. MADEIRA_LEAN_DIAG is left unset so diagnostic lines are not rate-limited,
        // and the 256 MB JIT dump on a crash stays off.
        setenv("MADEIRA_QUIET", "1", 1)
        unsetenv("MADEIRA_LEAN_DIAG")
        setenv("MADEIRA_JIT_DUMP", "0", 1)
        setenv("MONO_LOG_LEVEL", "warning", 0)
        sessionVulkanMode = profile.vulkanMode
        sessionD3D12Renderer = profile.d3d12Renderer
        sessionOpenGLBackend = profile.openGLBackend
        setenv("IDECK_DISPLAY_SCALING", RuntimeConfiguration.SurfaceMode(saved: profile.surfaceScaling).rawValue, 1)
        var controllerMode = profile.controllerAPI == "Automatic"
            ? (UserDefaults.standard.string(forKey: "wineControllerAPI") ?? "By controller")
            : profile.controllerAPI
        // By controller: a PlayStation pad (DualSense, DualShock 4) is given to the game
        // as a DualSense over HID (touchpad, motion, light, adaptive triggers); an Xbox
        // 360/One/Series pad as an Xbox controller (XInput); Joy-Con and Pro Controllers
        // (Switch 1 and 2) through XInput too, the API Windows games read for them.
        if controllerMode == "By controller" {
            controllerMode = InputManager.shared.connectedKind.isPlayStation ? "HID" : "XInput"
        }
        if controllerMode == "Nintendo Switch" { controllerMode = "XInput" }
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
        let metalFXOn = profile.metalFXEnabled && WindowsGameProfile.metalFXAllowed
        let resolution = Self.renderResolution(profile.resolution, metalFX: metalFXOn, screen: screen,
                                                performance: profile.metalFXPerformance)
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

        sessionMetalFXFactor = metalFXOn
            ? Self.metalFXFactor(resolution: resolution, screenLongSide: max(screen.width, screen.height))
            : nil
        if let factor = sessionMetalFXFactor {
            // DXMT only builds its MetalFX swapchain when this is set.
            setenv("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1", 1)
            SteamLog.event(String(format: "[wine-launch] MetalFX spatial upscaling %.2fx", factor))
        } else {
            unsetenv("DXMT_METALFX_SPATIAL_SWAPCHAIN")
            if profile.metalFXEnabled && !WindowsGameProfile.metalFXAllowed {
                SteamLog.event("[wine-launch] MetalFX off: this device has less than 8 GB of RAM")
            } else if profile.metalFXEnabled {
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

    /// The game's language (Game language on its page) as Windows' own language for this
    /// session. Wine takes the user and system locale from LC_ALL/LANG
    /// (build/ntdll-unix/env_ios.c init_locale) and, without them, from iOS's preferred
    /// language, so a game that picks its dubbing and subtitles from Windows' language
    /// (GetUserDefaultUILanguage, the locale) never saw the choice made in iDeck. With no
    /// choice, Wine follows the device as before.
    static func applyGameLanguage(profileID: String) {
        guard let tag = GameLanguage.choice(profileID) else {
            unsetenv("LC_ALL"); unsetenv("LANG")
            return
        }
        let unix = tag.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
        setenv("LC_ALL", unix, 1)
        setenv("LANG", unix, 1)
        SteamLog.event("[game-language] \(profileID): Windows language \(unix) for this session")
    }

    static func setD3D9OlderNvidia(_ on: Bool) {
        let keys: Set<String> = ["d3d9.customVendorId", "d3d9.customDeviceId", "d3d9.customDeviceDesc", "d3d9.customDriver"]
        let existing = getenv("DXMT_CONFIG").map { String(cString: $0) } ?? ""
        var options = existing.split(separator: ";").map(String.init).filter {
            !keys.contains($0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        if on { options += olderNvidiaD3D9 }
        setenv("DXMT_CONFIG", options.joined(separator: ";"), 1)
        if on { SteamLog.event("[wine-launch] d3d9 card: NVIDIA GeForce 7900 GS (10DE:0292)") }
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
    static func renderResolution(_ resolution: String, metalFX: Bool, screen: CGSize, performance: Bool = false) -> String {
        guard metalFX, resolution == "Device native", screen.width > 0, screen.height > 0 else { return resolution }
        let long = max(screen.width, screen.height), short = min(screen.width, screen.height)
        // Quality: 2/3 of the screen, enlarged 1.5x. Performance: half, enlarged 2x.
        let scale: CGFloat = performance ? 1.0 / 2.0 : 2.0 / 3.0
        let width = Int(long * scale) & ~1, height = Int(short * scale) & ~1
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
