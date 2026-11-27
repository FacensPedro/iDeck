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

    /// A game session is closing (the close button): Wine and the wineserver
    /// must finish writing before iOS may suspend iDeck. Set by SystemCoordinator.
    static var closingSession = false {
        didSet { if !closingSession { shared.endCloseTask() } }
    }
    var closeTask: UIBackgroundTaskIdentifier = .invalid

    var pressure: DispatchSourceMemoryPressure?
    var observers: [NSObjectProtocol] = []
    var pausedForBackground = false
    /// Called when the conditions for the display rate change.
    var onActivityChange: (() -> Void)?

    static var gameRunning: Bool { ideck_wineprocess_running() }
    static var appActive: Bool { UIApplication.shared.applicationState == .active }

    func start() {
        guard pressure == nil else { return }
        // Downloads the Sessions domain paused for a game go on once it ends.
        SessionLifecycle.shared.observe { _, next in
            guard next == .idle || next == .failed else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { ResourceDomains.sessionEnded() } }
        }
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

    // MARK: - Background

    /// Whether the display may be held at its maximum rate now.
    static var maxRateAllowed: Bool {
        gameRunning && appActive && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
