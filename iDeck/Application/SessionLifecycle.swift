import Foundation

/// iDeck 3.0: the central state of a Windows session, one state machine for every
/// launcher. SystemCoordinator reports each status it shows; this type maps it to a
/// state, accepts only the transitions the lifecycle allows, logs each one, and keeps
/// the history of the last session for the bug report. Later modules (launchers,
/// recovery, the session screen) read `state` instead of comparing status strings.
///
///   idle -> preparing -> launching -> running -> closing -> idle
///                 \-----------\----------\---> failed -> recovering -> idle
final class SessionLifecycle: @unchecked Sendable {
    enum State: String, CaseIterable, Sendable {
        case idle, preparing, launching, running, closing, failed, recovering
    }

    static let shared = SessionLifecycle()

    private let lock = NSLock()
    private var current: State = .idle
    private var history: [(Date, State, String)] = []

    var state: State { lock.lock(); defer { lock.unlock() }; return current }

    /// The transitions the lifecycle allows; anything else is logged and ignored.
    static let allowed: [State: Set<State>] = [
        .idle: [.preparing, .launching, .failed],
        .preparing: [.preparing, .launching, .failed, .idle],
        .launching: [.launching, .running, .failed, .closing, .idle],
        .running: [.closing, .failed, .idle],
        .closing: [.idle, .failed],
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
        if ok && previous != next {
            current = next
            history.append((Date(), next, status))
            if history.count > 64 { history.removeFirst(history.count - 64) }
        }
        lock.unlock()
        if previous != next {
            AppLog.record(ok ? "[session] \(previous.rawValue) -> \(next.rawValue) (\(status))"
                             : "[session] ignored \(previous.rawValue) -> \(next.rawValue) (\(status))")
        }
        return ok ? next : previous
    }

    /// The last transitions, oldest first, for the bug report.
    var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return history.suffix(16).map { "\(ISO8601DateFormatter().string(from: $0.0)) \($0.1.rawValue): \($0.2)" }
    }
}
