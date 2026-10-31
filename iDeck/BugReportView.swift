import SwiftUI
import UIKit

/// iDeck's own persistent log (Documents/iDeck-app-log.txt). Everything else
/// only reaches stdout, which nobody can read after the fact; this file is
/// what the Bugs & logs screen scans. Lines never contain credentials: the
/// callers (SteamLog, status updates) already redact them.
enum AppLog {
    static let maximumBytes: UInt64 = 1024 * 1024
    private static let queue = DispatchQueue(label: "ideck.app-log", qos: .utility)
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iDeck-app-log.txt", isDirectory: false)
    }

    /// The previous file, kept once when the current one reaches `maximumBytes`.
    static var rotatedURL: URL? {
        fileURL?.deletingPathExtension().appendingPathExtension("1.txt")
    }

    static func record(_ message: String) {
        let line = stamp.string(from: Date()) + " " + message.replacingOccurrences(of: "\n", with: " ⏎ ") + "\n"
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
               size + UInt64(data.count) > maximumBytes, let rotated = rotatedURL {
                try? manager.removeItem(at: rotated)
                try? manager.moveItem(at: url, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func clear() {
        queue.async {
            for url in [fileURL, rotatedURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// One problem found in a log: repeated lines that differ only in numbers,
/// addresses or thread ids are folded into a single entry with a count.
struct LogIssue: Identifiable, Hashable {
    enum Source: String { case app = "iDeck", wine = "Wine", jit = "JIT" }
    let id: String
    let source: Source
    let severity: Int          // 2 = error/crash, 1 = failure/warning
    let line: String           // the most recent occurrence
    var count: Int

    var copyText: String { "[\(source.rawValue)] " + (count > 1 ? "(×\(count)) " : "") + line }
}

enum LogIssueScanner {
    /// Patterns are matched case-insensitively against each line.
    private static let errors = [
        "error", "err:", "fatal", "crash", "exception", "panic", "abort",
        "c0000005", "c000001d", "c0000135", "status_access_violation", "unhandled",
    ]
    private static let failures = ["failed", "failure", "cannot", "could not", "unable to", "timed out", "timeout", "denied"]
    /// Wine debug channels that print "err:" for harmless probing.
    private static let noise = ["fixme:", "err:ole:", "err:winediag:"]

    static func scan(_ text: String, source: LogIssue.Source, limit: Int = 300) -> [LogIssue] {
        var found: [String: LogIssue] = [:]
        var order: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.count < 2000 else { continue }
            let lower = line.lowercased()
            if noise.contains(where: lower.contains) { continue }
            let severity = errors.contains(where: lower.contains) ? 2
                : failures.contains(where: lower.contains) ? 1 : 0
            guard severity > 0 else { continue }
            // JIT problems get their own group, whichever log they came from.
            let lineSource: LogIssue.Source = lower.contains("jit") ? .jit : source
            let key = lineSource.rawValue + ":" + normalized(lower)
            if var issue = found[key] {
                issue.count += 1
                found[key] = LogIssue(id: key, source: lineSource, severity: max(issue.severity, severity),
                                      line: String(line), count: issue.count)
            } else {
                found[key] = LogIssue(id: key, source: lineSource, severity: severity, line: String(line), count: 1)
                order.append(key)
            }
        }
        // Newest distinct problems first, errors before failures.
        return order.reversed().compactMap { found[$0] }
            .sorted { $0.severity > $1.severity }
            .prefix(limit).map { $0 }
    }

    /// Strips timestamps, hex values, numbers and thread prefixes so repeats fold together.
    static func normalized(_ line: String) -> String {
        var text = line
        for pattern in [#"^\S*\d{4}-\d\d-\d\dT\S+\s*"#, #"0x[0-9a-f]+"#, #"\b[0-9a-f]{6,}\b"#, #"\d+"#] {
            text = text.replacingOccurrences(of: pattern, with: "#", options: .regularExpression)
        }
        return text
    }
}

@MainActor
final class BugReportModel: ObservableObject {
    @Published private(set) var issues: [LogIssue] = []
    @Published private(set) var wineFinding: String?
    @Published private(set) var isScanning = false
    @Published private(set) var hasWineLog = false
    @Published private(set) var hasAppLog = false
    @Published var notice: String?

    static var wineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.txt", isDirectory: false)
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let wineURL = Self.wineLogURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let appURLs = [AppLog.rotatedURL, AppLog.fileURL].compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        hasWineLog = wineURL != nil
        hasAppLog = !appURLs.isEmpty
        let result = await Task.detached(priority: .userInitiated) { () -> ([LogIssue], Int32) in
            var issues: [LogIssue] = []
            let appText = appURLs.compactMap { try? WineLogClipboard.read(from: $0).text }.joined(separator: "\n")
            issues += LogIssueScanner.scan(appText, source: .app)
            var diagnosis: Int32 = 0
            if let wineURL {
                if let text = try? WineLogClipboard.read(from: wineURL).text {
                    issues += LogIssueScanner.scan(text, source: .wine)
                }
                diagnosis = wineURL.path.withCString { ideck_wine_log_diagnose($0) }
            }
            return (issues.sorted { $0.severity > $1.severity }, diagnosis)
        }.value
        issues = Self.liveJITIssues() + result.0
        wineFinding = Self.finding(for: result.1)
    }

    /// The JIT state of this process right now, as bugs: a missing debugger,
    /// a refused executable-memory pool and its exact reason.
    static func liveJITIssues() -> [LogIssue] {
        guard MadeiraBundleIdentity.isNative else { return [] }
        var lines: [(Int, String)] = []
        let snapshot = ideck_jit_snapshot()
        if !ideck_process_has_jit_permission() {
            lines.append((1, "JIT is not enabled for this iDeck process (CS_DEBUGGED off). Enable it in Settings › JIT."))
        } else if !snapshot.debugger_attached && !snapshot.wine_pool_prepared {
            lines.append((1, "JIT permission is active but the debugger is detached, so Wine's JIT pool cannot be prepared."))
        }
        let stage = ideck_wine_jit_pool_failure_stage()
        if stage != 0 {
            let reason: String
            switch stage {
            case 1: reason = "the debugger disconnected before Wine's executable memory was prepared"
            case 2: reason = "the debugger could not allocate Wine's RX region"
            case 3:
                switch ideck_wine_jit_pool_failure_rx_detail() {
                case 1: reason = "RX pool rejected: below Madeira's FEX frontier"
                case 2: reason = "RX pool rejected: address range overflow"
                case 3: reason = "RX pool rejected: outside the supported virtual-memory layout"
                case 4: reason = "RX pool rejected: overlaps the Windows image window"
                case 5: reason = "RX pool rejected: not page-aligned"
                case 6: reason = "RX pool rejected: Mach could not inspect it"
                case 7: reason = "RX pool rejected: unmapped gap"
                case 8: reason = "RX pool rejected: a page lacks execute permission"
                default: reason = "RX pool rejected"
                }
            case 4: reason = "iPadOS denied the RW mirror of the RX pool"
            case 5: reason = "iPadOS denied write access to the RW mirror"
            case 6: reason = "the pool addresses could not be exported to Wine"
            default: reason = "unknown failure stage \(stage)"
            }
            let mach = ideck_wine_jit_pool_failure_mach_code()
            lines.append((2, "Wine JIT pool error: \(reason)" + (mach != 0 ? " (Mach code \(mach))" : "") +
                          ", pool \(snapshot.wine_pool_mib) MiB."))
        }
        return lines.map { severity, line in
            LogIssue(id: "JIT-live:" + line, source: .jit, severity: severity, line: line, count: 1)
        }
    }

    /// What WineLogTriage's code means; shared with the in-game error banner.
    nonisolated static func finding(for diagnosis: Int32) -> String? {
        switch diagnosis {
        case 1: return "Last Wine log indicates an executable JIT allocation or mapping failure."
        case 2: return "Last Wine log indicates that executable memory permissions were denied."
        case 3: return "Last Wine log indicates the Windows process ran out of memory."
        case 4: return "Last Wine log indicates a Windows program memory access violation."
        case 5: return "Last Wine log indicates a missing or incompatible DLL."
        case 6: return "A 32-bit Windows program could not reserve its WoW64 address window. The iOS device's virtual address space is insufficient for the current Madeira memory policy."
        case 7: return "Wine/FEX encountered an unhandled native ARM64EC exception (x18 handler) and terminated with NTSTATUS 0xC000001D. This is a runtime compatibility failure, not proof of a missing game DLL."
        default: return nil
        }
    }

    func copy(_ issue: LogIssue) {
        UIPasteboard.general.string = report(for: [issue])
        notice = tr("Bug copied to the clipboard.")
    }

    func copyAll() {
        UIPasteboard.general.string = report(for: issues)
        notice = tr("All bugs copied to the clipboard.")
    }

    func copyLog(_ url: URL?) {
        guard let url, let content = try? WineLogClipboard.read(from: url) else {
            notice = tr("That log is empty.")
            return
        }
        UIPasteboard.general.string = content.text
        notice = tr("Log copied to the clipboard.")
    }

    func clearAppLog() {
        AppLog.clear()
        issues.removeAll { $0.source == .app }
        hasAppLog = false
    }

    /// A paste-ready report: device, app build and the selected problems.
    private func report(for selected: [LogIssue]) -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        var lines = [
            "iDeck bug report",
            "iDeck \(version), \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)",
            "Runtime: \(MadeiraBundleIdentity.isNative ? "Madeira-native" : "interface-only")",
        ]
        if let wineFinding { lines.append("Diagnosis: " + wineFinding) }
        lines.append("")
        lines += selected.map(\.copyText)
        return lines.joined(separator: "\n")
    }
}

struct BugReportView: View {
    @StateObject private var model = BugReportModel()
    @State private var expanded: Set<String> = []
    @AppStorage("diagnostics.detailed") private var detailedDiagnostics = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            List {
                if let finding = model.wineFinding {
                    Section(tr("Diagnosis")) {
                        Label(tr(finding), systemImage: "stethoscope")
                            .foregroundColor(.orange)
                    }
                }
                let jitIssues = model.issues.filter { $0.source == .jit }
                if !jitIssues.isEmpty {
                    Section(tr("JIT") + " (\(jitIssues.count))") {
                        ForEach(jitIssues) { issue in issueRow(issue) }
                    }
                }
                Section {
                    if model.isScanning && model.issues.isEmpty {
                        HStack { ProgressView(); Text(tr("Reading logs...")).foregroundColor(.gray) }
                    } else if model.issues.isEmpty {
                        Label(tr("No bugs found in the logs."), systemImage: "checkmark.seal")
                            .foregroundColor(.green)
                    } else {
                        ForEach(model.issues.filter { $0.source != .jit }) { issue in issueRow(issue) }
                    }
                } header: {
                    Text(tr("Bugs found") + (model.issues.isEmpty ? "" : " (\(model.issues.count))"))
                } footer: {
                    Text(tr("Tap a bug to see it in full. Copied reports include the iDeck version and device, never your Steam or GOG account."))
                }
                Section {
                    Toggle(tr("Detailed diagnostics"), isOn: $detailedDiagnostics)
                } footer: {
                    Text(tr("Turns on Madeira's profilers and full logs for the next game. They slow games down: use only to report a bug."))
                }
                Section(tr("Logs")) {
                    Button { model.copyAll() } label: {
                        Label(tr("Copy all bugs"), systemImage: "doc.on.doc")
                    }
                    .disabled(model.issues.isEmpty)
                    Button { model.copyLog(BugReportModel.wineLogURL) } label: {
                        Label(tr("Copy last Wine log"), systemImage: "terminal")
                    }
                    .disabled(!model.hasWineLog)
                    Button { model.copyLog(AppLog.fileURL) } label: {
                        Label(tr("Copy iDeck log"), systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!model.hasAppLog)
                    Button(role: .destructive) { model.clearAppLog() } label: {
                        Label(tr("Clear iDeck log"), systemImage: "trash")
                    }
                    .disabled(!model.hasAppLog)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(tr("Bugs & logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isScanning)
            }
        }
        .task { await model.scan() }
        .alert(model.notice ?? "", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(tr("OK"), role: .cancel) {}
        }
    }

    private func issueRow(_ issue: LogIssue) -> some View {
        let isOpen = expanded.contains(issue.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: issue.severity > 1 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(issue.severity > 1 ? .red : .orange)
                Text(issue.source.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.12), in: Capsule())
                if issue.count > 1 {
                    Text("×\(issue.count)").font(.caption2).foregroundColor(.gray)
                }
                Spacer()
                Button { model.copy(issue) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(tr("Copy bug"))
            }
            Text(issue.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(isOpen ? nil : 2)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(issue.id) } else { expanded.insert(issue.id) }
        }
    }
}
