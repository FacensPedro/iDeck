import Foundation

/// The part of Madeira's LogStore that its copied JIT files use
/// (StikJITHelper.swift, EntitlementChecker.swift): lines go to iDeck's log.
final class LogStore: @unchecked Sendable {
    enum Level: String { case info, success, warning, error }
    static let shared = LogStore()
    func log(_ message: String, level: Level = .info) {
        AppLog.record(level == .info ? message : "[\(level.rawValue)] \(message)")
    }
}
