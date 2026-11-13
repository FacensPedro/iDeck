import SwiftUI
import UIKit
import Darwin

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
        // The device's own clock and time zone (ISO 8601 defaults to UTC, "Z"):
        // log times match the time shown on the iPad.
        formatter.timeZone = .current
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

    /// Deletes the log now (waits for pending writes first), so a scan right
    /// after it no longer finds the old lines.
    static func clear() {
        queue.sync {
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
        "error", "err:", "fatal", "crash", "exception", "panic", "abort", "pressure critical",
        "c0000005", "c000001d", "c0000135", "status_access_violation", "unhandled",
        "checksum mismatch", "hash verification failed", "illegal instruction",
    ]
    private static let failures = [
        "failed", "failure", "cannot", "could not", "unable to", "timed out", "timeout",
        "denied", "warning", "warn:", "missing", "stale", "mprotect", "invalid",
        "wineserver timeout", "usbmux timeout", "no drawable available",
    ]
    /// Wine debug channels that print "err:" for harmless probing, and Madeira's
    /// informational lines that only look like failures: commit-zero's success
    /// counters ("stale=0/0"), ml990's address-space cap, the wineserver's infinite
    /// master-socket timeout and the iOS environment listing.
    private static let noise = ["fixme:", "err:ole:", "err:winediag:", "[commit-zero]", "guest ok",
                                "ml990:", "master_socket_timeout", "[ios env]"]
    /// Counters that report no problem at all ("launch-client-error=0").
    private static let zeroCount = try! NSRegularExpression(pattern: #"\b(error|errors|failed|failures|missing)\s*[=:]\s*0\b"#)
    /// Lines from iDeck's Steam client, downloads and Madeira Dock.
    private static let steamTags = ["[steam", "[dock", "steam client", "steam's", "madeira dock", "steamworks", "steam_api"]

    /// `steamSession` false leaves Steam-only lines out: they belong to an
    /// earlier Steam run, not to the game (GOG, Epic, any .exe) that failed.
    static func scan(_ text: String, source: LogIssue.Source, steamSession: Bool = true, limit: Int = 600) -> [LogIssue] {
        var found: [String: LogIssue] = [:]
        var order: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let original = raw.trimmingCharacters(in: .whitespaces)
            guard !original.isEmpty else { continue }
            // Native Wine output may include very long diagnostic lines.
            // Preserve both ends instead of silently discarding the problem.
            var line = original.count <= 2000
                ? String(original)
                : String(original.prefix(1200)) + " … " + String(original.suffix(750))
            var lower = line.lowercased()
            if noise.contains(where: lower.contains) { continue }
            // Wine's generic advice ("enable coredumps (ulimit -c unlimited)") does
            // not apply on iPadOS: point at the iOS crash diagnostics instead.
            if lower.contains("wineserver crashed") {
                line = "wineserver stopped unexpectedly. Wine's \"ulimit -c\" advice does not apply on iPadOS: see the [ios-crash] lines (MetricKit) and Settings › Privacy & Security › Analytics Data › iDeck."
                lower = line.lowercased()
            }
            if !steamSession, steamTags.contains(where: lower.contains) { continue }
            // Counts such as missing=0, errors=0 or failed=0 are normal
            // success telemetry. Remove only those zero-valued terms so a
            // real failure elsewhere in the same line remains visible.
            let range = NSRange(lower.startIndex..., in: lower)
            let actionable = zeroCount.stringByReplacingMatches(in: lower, range: range, withTemplate: "")
            // [touch] lines are diagnostics, not failures: kept so a report shows
            // where a tap that did nothing was sent.
            let severity = errors.contains(where: actionable.contains) ? 2
                : (failures.contains(where: actionable.contains) || lower.contains("[touch] tap")) ? 1 : 0
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
    /// The "Missing DLLs:" line of the report, from the last Wine log.
    @Published private(set) var missingModules: String?
    @Published private(set) var isScanning = false
    @Published private(set) var hasWineLog = false
    @Published private(set) var hasAppLog = false
    @Published var notice: String?
    private var scanGeneration = 0

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
        let steamSession = UserDefaults.standard.bool(forKey: "session.lastWasSteam")
        let generation = scanGeneration
        let result = await Task.detached(priority: .userInitiated) { () -> ([LogIssue], Int32, String) in
            var issues: [LogIssue] = []
            let appText = appURLs.compactMap { try? WineLogClipboard.read(from: $0).text }.joined(separator: "\n")
            issues += LogIssueScanner.scan(appText, source: .app, steamSession: steamSession)
            var diagnosis: Int32 = 0
            var missing = MissingModuleScanner.summary(nil)
            if let wineURL {
                if let text = try? WineLogClipboard.read(from: wineURL).text {
                    issues += LogIssueScanner.scan(text, source: .wine, steamSession: steamSession)
                    missing = MissingModuleScanner.summary(text)
                }
                diagnosis = wineURL.path.withCString { ideck_wine_log_diagnose($0) }
            }
            return (issues.sorted { $0.severity > $1.severity }, diagnosis, missing)
        }.value
        // Clearing logs while a read is in flight must not restore stale bugs.
        guard generation == scanGeneration, !Task.isCancelled else { return }
        issues = Self.liveJITIssues() + result.0
        wineFinding = Self.finding(for: result.1)
        missingModules = result.2
    }

    /// The JIT state of this process right now, as bugs: a missing debugger,
    /// a refused executable-memory pool and its exact reason.
    static func liveJITIssues() -> [LogIssue] {
        guard MadeiraBundleIdentity.isNative else { return [] }
        var lines: [(Int, String)] = []
        let snapshot = ideck_jit_snapshot()
        if !ideck_process_has_jit_permission() {
            // A report made after a crash runs in a new process, where CS_DEBUGGED is
            // off again: say what JIT was at the last launch, too.
            let last = UserDefaults.standard.string(forKey: SystemCoordinator.lastLaunchJITKey)
            lines.append((1, "JIT is not enabled in this iDeck process (CS_DEBUGGED off) at report time"
                + (last.map { "; at the last launch: " + $0 } ?? "; no launch had JIT prepared")
                + ". iDeck opens StikDebug itself at the next launch."))
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
        if stage == 0, let failure = StikJITHelper.poolFailure {
            lines.append((2, "Wine JIT pool error: \(failure)"))
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
        case 8: return "Wine recorded a stale ARM64EC import address in its JIT executable copy and a Windows game access violation (0xC0000005). The synchronization discrepancy requires native Wine/FEX investigation; these logs do not prove it caused the crash."
        case 9: return "WineServer reported a startup, connection, or unexpected-exit failure. Inspect its native log for the actual cause."
        case 10: return "The graphics pipeline reported a DXMT, Direct3D 12, Metal presentation, or shader compilation failure. This does not establish which component caused it."
        case 11: return "The guest log reported an illegal or unsupported CPU instruction (0xC000001D). Check the game executable and FEX translation logs."
        case 12: return "A network or USB transport reported a connection failure. Check the device's connectivity."
        case 13: return "Download or installation integrity verification failed. Check hashes and retry only the affected data."
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

    /// Logging evidence must remain available throughout active downloads
    /// and transfers; paused jobs do not count as an active transfer.
    static var downloadsOrTransfersActive: Bool {
        let steam = SteamOwnedGamesModel.shared
        if steam.installingApps.contains(where: { !steam.pausedInstalls.contains($0) }) { return true }
        let gog = GOGLibraryModel.shared
        if gog.downloadProgress.keys.contains(where: { !gog.pausedDownloads.contains($0) }) { return true }
        let epic = EpicLibrary.shared
        if epic.downloads.values.contains(where: { download in
            if case .paused = download.state { return false }
            if case .failed = download.state { return false }
            return true
        }) { return true }
        return false
    }

    /// Clears every log the bug list reads: iDeck's own log and the last
    /// Wine log. Live JIT state is checked again, not cleared.
    func clearLogs() {
        guard !Self.downloadsOrTransfersActive else {
            notice = "Pause or finish the download and transfer before clearing logs."
            return
        }
        scanGeneration += 1
        AppLog.clear()
        if let wine = Self.wineLogURL {
            try? FileManager.default.removeItem(at: wine)
        }
        hasAppLog = false
        hasWineLog = false
        wineFinding = nil
        missingModules = nil
        issues = Self.liveJITIssues()
        notice = tr("Logs cleared.")
    }

    /// Hardware identification uses the device's actual machine identifier.
    /// Unknown and future devices are reported by identifier, never guessed.
    static var hardwareSummary: String {
        var bytes = [CChar](repeating: 0, count: 128)
        var length = bytes.count
        let value: String
        if sysctlbyname("hw.machine", &bytes, &length, nil, 0) == 0 {
            value = String(cString: bytes)
        } else {
            value = UIDevice.current.model
        }
        let device: String
        switch value {
        case "iPhone15,4": device = "iPhone 15"
        case "iPhone15,5": device = "iPhone 15 Plus"
        case "iPad16,1", "iPad16,2": device = "iPad mini (A17 Pro)"
        default: device = UIDevice.current.model + " (" + value + ")"
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return "\(device) [\(value)]; \(cores) active logical CPU cores"
    }

    static var gameContext: String {
        let defaults = UserDefaults.standard
        let launcher = defaults.string(forKey: "diagnostics.lastLauncher") ?? "Unknown"
        let game = defaults.string(forKey: "diagnostics.lastGame") ?? "Not recorded"
        return "Game: \(game) | Launcher: \(launcher)"
    }

    /// What the problems happened in: build, memory, Memory+, JIT, runtime and storage.
    static var environmentLines: [String] {
        func name(_ state: MemoryPlus.State) -> String {
            switch state {
            case .granted: return "active"
            case .missing: return "not granted"
            case .unknown: return "unknown"
            }
        }
        let runtime = MadeiraBundleIdentity.profile
        let defaults = UserDefaults.standard
        let physical = ProcessInfo.processInfo.physicalMemory / 1_048_576
        let pool = defaults.object(forKey: "wineJITPoolMiB") as? Int ?? 560
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let free = (try? documents?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return [
            "Build: commit \(runtime["sourceCommit"] as? String ?? "unknown"), graphics \(MadeiraBundleIdentity.graphicsProfile)",
            "Memory: \(physical) MB physical, \(ResourceGovernor.availableMiB()) MB still allowed by iOS",
            "Memory+: increased limit \(name(MemoryPlus.increasedLimit)), extended addressing \(name(MemoryPlus.extendedAddressing))",
            "JIT: method \(defaults.string(forKey: SystemCoordinator.jitMethodKey) ?? "stikdebug"), pool \(pool) MB",
            "Windows runtime: x64 \(MadeiraRuntime.installed("wine-x64") ? "installed" : "missing"), x86 \(MadeiraRuntime.installed("wine-x86") ? "installed" : "missing")",
            "Device language: \(Locale.preferredLanguages.first ?? "unknown")"
                + (free.map { ", storage free: \($0 / 1_073_741_824) GB" } ?? ""),
        ]
    }

    /// A paste-ready report: device, app build and the selected problems.
    private func report(for selected: [LogIssue]) -> String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        var lines = [
            "iDeck bug report",
            "iDeck \(version), iOS \(UIDevice.current.systemVersion)",
            "Hardware: " + Self.hardwareSummary,
            Self.gameContext,
            "Runtime: \(MadeiraBundleIdentity.isNative ? "native" : "interface-only")",
        ]
        lines += Self.environmentLines
        if (UserDefaults.standard.string(forKey: "diagnostics.lastLauncher") ?? "").hasPrefix("EA"),
           let facts = UserDefaults.standard.string(forKey: EALibrary.licenceFactsKey) {
            lines.append("EA licence: " + facts)
            if selected.contains(where: { $0.line.contains("ActivationUI.exe") }) {
                lines.append("EA: the game started ActivationUI.exe, EA's activation window: it did not accept the licence on disk.")
            }
        }
        if let missingModules { lines.append("Missing DLLs: " + missingModules) }
        if let wineFinding { lines.append("Diagnosis: " + wineFinding) }
        lines.append("")
        lines += selected.map(\.copyText)
        return lines.joined(separator: "\n")
    }
}

struct BugReportView: View {
    @StateObject private var model = BugReportModel()
    @State private var expanded: Set<String> = []
    // Both groups start collapsed: the report opens as a short summary.
    @State private var bugsOpen = false
    @State private var jitOpen = false
    @State private var showClearConfirmation = false
    @AppStorage(BenchmarkSession.enabledKey) private var recordBenchmarks = false
    @State private var benchmarkReports: [URL] = []

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
                    Section {
                        if jitOpen { ForEach(jitIssues) { issue in issueRow(issue) } }
                    } header: {
                        Button { withAnimation { jitOpen.toggle() } } label: {
                            HStack {
                                Text(tr("JIT") + " (\(jitIssues.count))")
                                Spacer()
                                Image(systemName: "chevron.down").rotationEffect(.degrees(jitOpen ? 0 : -90))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                let gameIssues = model.issues.filter { $0.source != .jit }
                Section {
                    if model.isScanning && gameIssues.isEmpty {
                        HStack { ProgressView(); Text(tr("Reading logs...")).foregroundColor(.gray) }
                    } else if gameIssues.isEmpty {
                        Label(tr("No bugs found in the logs."), systemImage: "checkmark.seal")
                            .foregroundColor(.green)
                    } else if bugsOpen {
                        ForEach(gameIssues) { issue in issueRow(issue) }
                    }
                } header: {
                    // Show detected problems immediately. Users may collapse
                    // the section, but should never need to discover a hidden list.
                    Button {
                        withAnimation { bugsOpen.toggle() }
                    } label: {
                        HStack {
                            Text(tr("Bugs found") + (gameIssues.isEmpty ? "" : " (\(gameIssues.count))"))
                            Spacer()
                            if !gameIssues.isEmpty {
                                Image(systemName: "chevron.down").rotationEffect(.degrees(bugsOpen ? 0 : -90))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    Toggle(tr("Record benchmarks"), isOn: $recordBenchmarks)
                    ForEach(benchmarkReports.prefix(20), id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "chart.bar.doc.horizontal")
                                .font(.caption.monospaced())
                        }
                    }
                } header: {
                    Text(tr("Benchmarks"))
                } footer: {
                    Text(tr("Records each game session and each Steam or Epic install: FPS, frame times, CPU, memory, thermal state and install speed. Reports are saved in Files › iDeck › iDeck › Benchmarks."))
                }
                .onAppear { benchmarkReports = BenchmarkSession.reports() }
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
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Label(tr("Clear logs"), systemImage: "trash")
                    }
                    .disabled((!model.hasAppLog && !model.hasWineLog) || BugReportModel.downloadsOrTransfersActive)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog("Clear diagnostic logs?", isPresented: $showClearConfirmation) {
            Button(tr("Clear logs"), role: .destructive) { model.clearLogs() }
            Button(tr("Cancel"), role: .cancel) { }
        } message: {
            Text("This action cannot be undone. Games and settings will not be changed.")
        }
        .navigationTitle(tr("Bugs & logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isScanning)
            }
        }
        .task {
            // New errors may be written by Wine after the screen opens.
            // Rescan only while Bugs & logs is visible; cancellation stops
            // polling when the user leaves this page.
            await model.scan()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { break }
                guard !Task.isCancelled else { break }
                await model.scan()
            }
        }
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

/// DLLs and functions the last Windows session could not find, from Wine's own messages:
/// a missing import library, a library that failed to load, an import with no
/// implementation, an unimplemented function that was called, and a DLL looked up in
/// system32/syswow64 (the last place Windows searches) that is not there.
enum MissingModuleScanner {
    private static let rules: [(pattern: String, format: ([Substring]) -> String)] = [
        (#"Library ([^ ]+) \(which is needed by L?"?([^)"]+)"?\) not found"#, { "\($0[0]) (needed by \(name($0[1])))" }),
        (#"Loading library ([^ ]+) \(which is needed by L?"?([^)"]+)"?\) failed"#, { "\($0[0]) (failed to load, needed by \(name($0[1])))" }),
        (#"[Cc]ould not load L?"?([^ ",]+)"?, status"#, { "\(name($0[0])) (could not load)" }),
        (#"No implementation for ([^ .]+(?:\.dll)?)\.([^ ]+) imported from L?"?([^ ,"]+)"#, { "\($0[0]).\($0[1]) (function, imported by \(name($0[2])))" }),
        (#"[Uu]nimplemented function ([^ .]+(?:\.dll)?)\.([^ ]+) called"#, { "\($0[0]).\($0[1]) (unimplemented function called)" }),
        (#"\\+windows\\+(?:system32|syswow64)\\+([^\\" ]+\.dll)"? not found"#, { "\($0[0]) (not in system32)" }),
    ]

    private static func name(_ path: Substring) -> String {
        String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? path)
    }

    /// Every distinct finding in the log, in the order first seen.
    static func findings(in text: String) -> [String] {
        var seen = Set<String>(), result: [String] = []
        let compiled = rules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])).map { ($0, rule.format) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            for (regex, format) in compiled {
                guard let match = regex.firstMatch(in: string, range: range) else { continue }
                let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: string).map { string[$0] } }
                let finding = format(groups)
                if seen.insert(finding.lowercased()).inserted { result.append(finding) }
                break
            }
            if result.count >= 40 { break }
        }
        return result
    }

    /// The report line: the findings, or that the log has none (or no log exists).
    static func summary(_ text: String?) -> String {
        guard let text else { return "no Wine log to check" }
        let found = findings(in: text)
        return found.isEmpty ? "none reported in the Wine log" : found.joined(separator: "; ")
    }
}
