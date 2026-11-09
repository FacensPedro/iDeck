import Foundation
import MetricKit

// Crash diagnostics the iPadOS way. Wine's own advice when its server dies,
// "enable coredumps (ulimit -c unlimited)", does not apply: iOS apps get no core
// files. The wineserver runs inside iDeck's process (WineServerBridge), so when it
// dies iOS records a crash report for iDeck, and MetricKit delivers it at the next
// launch as an MXCrashDiagnostic: exception type and code, signal, termination
// reason, the faulting virtual-memory region and every thread's call stack. Each
// one is summarised into the app log (tag [ios-crash], picked up by bug reports)
// and kept whole as JSON in Documents/Diagnostics. Hangs and CPU or disk
// exceptions are summarised too.

final class IOSCrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = IOSCrashDiagnostics()

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Payloads iOS already delivered before this run subscribed.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] { record(crash, kind: "crash", payload: payload) }
            for hang in payload.hangDiagnostics ?? [] {
                AppLog.record("[ios-crash] hang of \(hang.hangDuration) in \(hang.metaData.applicationBuildVersion)")
                save(hang.jsonRepresentation(), kind: "hang", payload: payload)
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                AppLog.record("[ios-crash] CPU exception: \(cpu.totalCPUTime) over \(cpu.totalSampledTime)")
            }
        }
    }

    private func record(_ crash: MXCrashDiagnostic, kind: String, payload: MXDiagnosticPayload) {
        var parts = ["build \(crash.metaData.applicationBuildVersion)"]
        if let type = crash.exceptionType { parts.append("exception type \(type)") }
        if let code = crash.exceptionCode { parts.append("code \(code)") }
        if let signal = crash.signal { parts.append("signal \(signal)") }
        if let reason = crash.terminationReason, !reason.isEmpty { parts.append("reason \(reason)") }
        if let region = crash.virtualMemoryRegionInfo, !region.isEmpty {
            parts.append("region \(region.replacingOccurrences(of: "\n", with: " ").prefix(240))")
        }
        let wine = Self.mentionsWine(crash.callStackTree.jsonRepresentation())
        AppLog.record("[ios-crash] iDeck crashed (\(parts.joined(separator: ", ")))"
                      + (wine ? "; the crashing stacks are in Wine/wineserver code" : ""))
        save(crash.jsonRepresentation(), kind: kind, payload: payload)
    }

    /// Whether a call-stack tree names Wine's server or loader frames.
    static func mentionsWine(_ json: Data) -> Bool {
        let text = String(decoding: json, as: UTF8.self).lowercased()
        return ["wineserver", "wine_", "ntdll", "madeira"].contains { text.contains($0) }
    }

    private func save(_ json: Data, kind: String, payload: MXDiagnosticPayload) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd).replacingOccurrences(of: ":", with: "-")
        let url = Self.folder.appendingPathComponent("\(kind)-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        try? json.write(to: url, options: .atomic)
        // Keep the newest 20.
        let files = ((try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        for old in files.dropFirst(20) { try? fm.removeItem(at: old) }
    }
}
