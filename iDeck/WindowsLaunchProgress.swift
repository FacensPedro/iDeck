import Foundation

enum WindowsLaunchProgress {
    static func stage(for status: String) -> Int? {
        switch status {
        case "Preparing game launch...": return 10
        case "Preparing Wine prefix...": return 20
        case "Installing Microsoft Visual C++...": return 35
        case "Launching Steam game...", "Launching Windows app...", "Launching Steam client...": return 70
        case "Running", "Steam Running": return 90
        default: return nil
        }
    }

    static func advance(current: Int, status: String) -> Int {
        guard let stage = stage(for: status) else { return current }
        return max(current, stage)
    }

    static func afterFirstFrame(current: Int, wineRunning: Bool) -> Int {
        wineRunning ? 100 : current
    }

    static func shouldDisplay(status: String, percentage: Int) -> Bool {
        guard percentage > 0 && percentage < 100 else { return false }
        return stage(for: status) != nil
    }
}
