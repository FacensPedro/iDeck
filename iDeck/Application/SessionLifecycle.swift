import Foundation

/// iDeck 3.0: the central state of a Windows session, one state machine for every
/// launcher. SystemCoordinator reports each status it shows; this type maps it to a
/// state, accepts only the transitions the lifecycle allows, logs each one, and keeps
/// the history of the last session for the bug report. Later modules (launchers,
/// recovery, the session screen) read `state` instead of comparing status strings.
///
///   idle -> preparing -> launching -> running -> closing -> idle
///                 \-----------\----------\---> failed -> recovering -> idle
///
/// 3.1: each transition records how long the previous state lasted; a monitor
/// notes a session that stays too long in preparing, launching or closing (once per
/// state entered); observers hear every transition; and "Freeing memory" before a
/// launch (iDeck reopening through StikDebug from idle) is a transition, not ignored.
final class SessionLifecycle: @unchecked Sendable {
    enum State: String, CaseIterable, Sendable {
        case idle, preparing, launching, running, closing, failed, recovering
    }

    static let shared = SessionLifecycle()

    private let lock = NSLock()
    private var current: State = .idle
    private var enteredAt = Date()
    private var history: [(Date, State, String, TimeInterval)] = []
    private var stallNoted = false
    private var observers: [(State, State) -> Void] = []
    private var monitor: DispatchSourceTimer?

    /// How long a state may last before the monitor writes it down.
    static let stallSeconds: [State: TimeInterval] = [.preparing: 180, .launching: 120, .closing: 45, .recovering: 60]

    /// Seconds spent in the current state.
    var timeInState: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(enteredAt) }

    /// Called on every accepted transition (previous, next), on the reporting thread.
    func observe(_ observer: @escaping (State, State) -> Void) {
        lock.lock(); observers.append(observer); lock.unlock()
    }

    var state: State { lock.lock(); defer { lock.unlock() }; return current }

    /// The transitions the lifecycle allows; anything else is logged and ignored.
    static let allowed: [State: Set<State>] = [
        .idle: [.preparing, .launching, .failed, .recovering],
        .preparing: [.preparing, .launching, .failed, .idle],
        .launching: [.launching, .running, .failed, .closing, .idle],
        .running: [.closing, .failed, .idle],
        .closing: [.idle, .failed, .recovering],
        .failed: [.recovering, .idle, .preparing, .launching],
        .recovering: [.idle, .preparing, .launching, .failed],
    ]

    /// The state a status line means, or nil when it changes nothing.
    static func state(for status: String) -> State? {
        switch status {
        case "Preparing Windows Environment...", "Preparing Wine prefix...", "Preparing executable...",
             "Windows Runtime Ready":
            return .preparing
        case "Launching Steam game...", "Launching Windows app...", "Wine started; waiting for game...":
            return .launching
        case "Running", "Steam Running":
            return .running
        case "Closing Windows session...":
            return .closing
        case "Windows Ready":
            return .idle
        default:
            if status.hasPrefix("Execution Error") || status.hasPrefix("Cannot launch") { return .failed }
            if status.hasPrefix("Freeing memory") { return .recovering }
            return nil
        }
    }

    @discardableResult
    func report(status: String) -> State? {
        guard let next = Self.state(for: status) else { return nil }
        lock.lock()
        let previous = current
        let ok = previous == next || Self.allowed[previous]?.contains(next) == true
        var lasted: TimeInterval = 0
        var notify: [(State, State) -> Void] = []
        if ok && previous != next {
            let now = Date()
            lasted = now.timeIntervalSince(enteredAt)
            current = next
            enteredAt = now
            stallNoted = false
            history.append((now, next, status, lasted))
            if history.count > 64 { history.removeFirst(history.count - 64) }
            notify = observers
        }
        lock.unlock()
        if previous != next {
            AppLog.record(ok ? "[session] \(previous.rawValue) -> \(next.rawValue) after \(String(format: "%.1f", lasted)) s (\(status))"
                             : "[session] ignored \(previous.rawValue) -> \(next.rawValue) (\(status))")
        }
        if ok && previous != next {
            startMonitorIfNeeded()
            notify.forEach { $0(previous, next) }
        }
        return ok ? next : previous
    }

    /// The last transitions, oldest first, for the bug report: when, the state entered,
    /// the status that caused it and how long the state before it lasted.
    var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        let format = ISO8601DateFormatter()
        return history.suffix(16).map {
            "\(format.string(from: $0.0)) \($0.1.rawValue) (previous state \(String(format: "%.1f", $0.3)) s): \($0.2)"
        }
    }

    /// Checks every 5 s, while a session is not idle, whether it is stuck in a state.
    private func startMonitorIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard monitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkStall() }
        timer.resume()
        monitor = timer
    }

    private func checkStall() {
        lock.lock()
        let state = current, since = Date().timeIntervalSince(enteredAt)
        var note = false
        if let limit = Self.stallSeconds[state], since >= limit, !stallNoted {
            stallNoted = true
            note = true
        }
        if state == .idle || state == .failed, let timer = monitor {
            timer.cancel()
            monitor = nil
        }
        lock.unlock()
        if note {
            AppLog.record("[session] stalled: \(state.rawValue) for \(Int(since)) s"
                          + (state == .launching ? " without a first image" : state == .closing ? " while Wine has not exited" : ""))
        }
    }
}
