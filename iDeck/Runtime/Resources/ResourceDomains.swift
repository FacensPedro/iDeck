// ResourceDomains.swift
// iDeck 3.0.1: the Resource Governor's four domains, each with its own level.

import Foundation
import Darwin

/// What the Resource Governor controls, one domain at a time:
/// - FEX: the x86 translator's share of the CPU (cores shown to the game, x87 precision),
/// - JIT: the size of the translated-code pool,
/// - GPU: frames in flight and frame generation,
/// - Sessions: memory before a launch, store downloads during a game, the game in the
///   background.
/// Each domain is Automatic (iDeck decides from the device's state: Low Power Mode, heat,
/// free memory), Economy (less heat, battery and memory) or Performance (as much as the
/// device gives). A game's own page always wins over a domain's level.
enum ResourceDomain: String, CaseIterable, Sendable {
    case fex, jit, gpu, sessions

    var title: String {
        switch self {
        case .fex: return "FEX"
        case .jit: return "JIT"
        case .gpu: return "GPU"
        case .sessions: return tr("Sessions")
        }
    }
}

enum ResourceLevel: String, CaseIterable, Sendable {
    case automatic = "Automatic", economy = "Economy", performance = "Performance"

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .economy: return tr("Economy")
        case .performance: return tr("Performance")
        }
    }
}

enum ResourceDomains {
    static func key(_ domain: ResourceDomain) -> String { "resources.level." + domain.rawValue }

    /// The level chosen in Settings for a domain.
    static func level(_ domain: ResourceDomain) -> ResourceLevel {
        UserDefaults.standard.string(forKey: key(domain)).flatMap(ResourceLevel.init(rawValue:)) ?? .automatic
    }

    static func set(_ level: ResourceLevel, for domain: ResourceDomain) {
        UserDefaults.standard.set(level.rawValue, forKey: key(domain))
        AppLog.record("[resources] \(domain.rawValue): \(level.rawValue)")
    }

    /// The device is hot or saving power: Automatic acts as Economy.
    static var deviceConstrained: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical
    }

    /// The level a domain has for this launch: Automatic resolved against the device.
    static func effective(_ domain: ResourceDomain, availableMiB: Int = Int(os_proc_available_memory() >> 20)) -> ResourceLevel {
        let chosen = level(domain)
        guard chosen == .automatic else { return chosen }
        if deviceConstrained { return .economy }
        // Little memory left: the JIT pool and the GPU's frames in flight go first.
        if availableMiB < 3072, domain == .jit || domain == .gpu { return .economy }
        return .automatic
    }

    // MARK: - The plan for a launch

    struct Plan: Equatable {
        /// MADEIRA_CPU_COUNT for a game whose page leaves the count to iDeck (nil: all).
        var cpuCount: Int?
        /// FEX_X87REDUCEDPRECISION forced on (faster x87 maths, less exact).
        var reducedX87 = false
        /// The JIT pool for a game whose page leaves its size to iDeck (nil: Settings).
        var jitPoolMiB: Int?
        /// DXMT_MAX_FRAME_LATENCY (nil: iDeck's memory rule).
        var frameLatency: Int?
        var frameGeneration = true
        /// Memory handed back before the launch.
        var trimBeforeLaunch = false
        /// Store downloads paused while the game runs, resumed after.
        var pauseDownloads = false
        /// nil: Settings' "Pause games in the background".
        var pauseInBackground: Bool?
    }

    static func plan(profile: WindowsGameProfile, availableMiB: Int = Int(os_proc_available_memory() >> 20),
                     cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Plan {
        var plan = Plan()
        switch effective(.fex, availableMiB: availableMiB) {
        case .economy:
            if profile.cpuCount == 0 { plan.cpuCount = min(4, cores) }
            plan.reducedX87 = true
        case .performance:
            plan.reducedX87 = true
        case .automatic:
            break
        }
        if profile.jitPoolMiB == 0 {
            switch effective(.jit, availableMiB: availableMiB) {
            case .economy: plan.jitPoolMiB = 384
            case .performance: plan.jitPoolMiB = 560
            case .automatic: break
            }
        }
        switch effective(.gpu, availableMiB: availableMiB) {
        case .economy:
            plan.frameLatency = 1
            plan.frameGeneration = false
        case .performance:
            // Two frames in flight unless memory is really short.
            plan.frameLatency = availableMiB < 2048 ? 1 : 2
        case .automatic:
            break
        }
        switch effective(.sessions, availableMiB: availableMiB) {
        case .economy:
            plan.trimBeforeLaunch = true
            plan.pauseDownloads = true
            plan.pauseInBackground = true
        case .performance:
            plan.pauseInBackground = false
        case .automatic:
            break
        }
        return plan
    }

    /// The plan of the session being launched (read by the background rule).
    nonisolated(unsafe) static var current = Plan()
    /// Downloads this governor paused for the session, resumed when it ends.
    nonisolated(unsafe) static var pausedForSession: [StoreGameRef] = []

    /// Applies the plan to the session's environment, after the game's profile.
    /// Returns the plan, which the JIT part writes into the session config.
    @discardableResult
    static func apply(profile: WindowsGameProfile) -> Plan {
        let plan = plan(profile: profile)
        current = plan
        if let count = plan.cpuCount { setenv("MADEIRA_CPU_COUNT", String(count), 1) }
        if plan.reducedX87 { setenv("FEX_X87REDUCEDPRECISION", "1", 1) }
        if let latency = plan.frameLatency {
            setenv("DXMT_MAX_FRAME_LATENCY", String(latency), 1)
            // Not a game's own setting: the next launch works its value out again.
            WindowsEnvironment.lowMemoryFrameLatency = true
        }
        if !plan.frameGeneration { unsetenv("MADEIRA_FRAMEGEN") }
        if plan.trimBeforeLaunch {
            URLCache.shared.removeAllCachedResponses()
            let returned = malloc_zone_pressure_relief(nil, 0)
            AppLog.record("[resources] sessions: \(returned >> 20) MiB handed back before the launch")
        }
        if plan.pauseDownloads {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { pausedForSession += StoreProviders.pauseAll() }
            }
        }
        AppLog.record("[resources] launch plan: " + describe(plan))
        return plan
    }

    /// A session ended (idle or failed): downloads paused for it go on.
    @MainActor
    static func sessionEnded() {
        guard !pausedForSession.isEmpty else { return }
        let games = pausedForSession
        pausedForSession = []
        StoreProviders.resume(games, prefix: nil)
        AppLog.record("[resources] sessions: \(games.count) download(s) resumed after the game")
    }

    static func describe(_ plan: Plan) -> String {
        let levels = ResourceDomain.allCases.map { domain -> String in
            let chosen = level(domain), used = effective(domain)
            return "\(domain.rawValue)=\(chosen.rawValue)" + (chosen != used ? "->\(used.rawValue)" : "")
        }.joined(separator: " ")
        var parts = [levels]
        if let count = plan.cpuCount { parts.append("cpu \(count)") }
        if plan.reducedX87 { parts.append("x87 reduced") }
        if let pool = plan.jitPoolMiB { parts.append("pool \(pool) MB") }
        if let latency = plan.frameLatency { parts.append("frames in flight \(latency)") }
        if !plan.frameGeneration { parts.append("frame generation off") }
        if plan.pauseDownloads { parts.append("downloads paused") }
        if let pause = plan.pauseInBackground { parts.append(pause ? "pause in background" : "runs in background") }
        return parts.joined(separator: ", ")
    }
}
