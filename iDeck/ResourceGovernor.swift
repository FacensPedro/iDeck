import AVFoundation
import Foundation
import UIKit

/// Keeps iDeck's CPU, GPU and memory use down while a game is not being played,
/// following steamac (fxgl/steamac): it suspends the VM when its window is in the
/// background and watches memory pressure so the system does not kill the session.
///
/// - Background: with "Pause games in the background" (on by default) the audio
///   session is deactivated when iDeck leaves the screen during a game. The
///   `audio` background mode otherwise keeps the whole Wine session running,
///   emulating the game on the CPU while its GPU work is refused in the
///   background. Without active audio iOS suspends iDeck: no CPU or GPU use, the
///   game's memory kept. Downloads keep their own background tasks.
/// - Memory pressure: on a warning iDeck drops what it can rebuild (network and
///   artwork caches) and logs the footprint and what is left before the system's
///   limit (os_proc_available_memory), the measure Madeira also advertises to
///   games as their memory.
/// - Display rate: "Hold Display at Maximum Rate" holds 120 Hz only while a game
///   runs on screen, never in menus, in the background or in Low Power Mode.
///
/// iOS gives apps no swap file of their own; on iPads with an M-series chip the
/// system swaps by itself. iDeck already asks for the increased memory limit.
@MainActor
final class ResourceGovernor {
    static let shared = ResourceGovernor()
    static let pauseInBackgroundKey = "resources.pauseGamesInBackground"
    static let releaseCachesNotification = Notification.Name("iDeckReleaseCaches")

    static var pauseInBackground: Bool {
        UserDefaults.standard.object(forKey: pauseInBackgroundKey) as? Bool ?? true
    }

    private var pressure: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private(set) var pausedForBackground = false
    /// Called when the conditions for the display rate change.
    var onActivityChange: (() -> Void)?

    static var gameRunning: Bool { ideck_wineprocess_running() }
    static var appActive: Bool { UIApplication.shared.applicationState == .active }

    func start() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.memoryPressure(source.data) }
        }
        source.resume()
        pressure = source
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringForeground() }
        })
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onActivityChange?() }
            })
        }
    }

    // MARK: - Memory

    static func footprintMiB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }

    static func availableMiB() -> Int { Int(os_proc_available_memory() >> 20) }

    private func memoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let level = event.contains(.critical) ? "critical" : "warning"
        let before = Self.footprintMiB()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: Self.releaseCachesNotification, object: nil)
        AppLog.record("[memory] pressure \(level): footprint \(before) MiB -> \(Self.footprintMiB()) MiB after releasing caches, " +
                      "\(Self.availableMiB()) MiB left before the system limit, game running: \(Self.gameRunning)")
        BenchmarkSession.mark("memory_pressure_" + level)
    }

    // MARK: - Background

    private func enteredBackground() {
        onActivityChange?()
        guard Self.pauseInBackground, Self.gameRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            pausedForBackground = true
            AppLog.record("[resources] game paused in the background (audio session off; iOS suspends iDeck)")
        } catch {
            AppLog.record("[resources] could not pause the game in the background: \(error.localizedDescription)")
        }
    }

    private func enteringForeground() {
        if pausedForBackground {
            pausedForBackground = false
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                AppLog.record("[resources] game resumed (audio session on)")
            } catch {
                AppLog.record("[resources] audio session could not resume: \(error.localizedDescription)")
            }
        }
        onActivityChange?()
    }

    /// Whether the display may be held at its maximum rate now.
    static var maxRateAllowed: Bool {
        gameRunning && appActive && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
