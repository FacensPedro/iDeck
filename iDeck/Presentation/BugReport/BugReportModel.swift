// BugReportModel.swift
// Split from BugReportView.swift (iDeck 3.0 architecture).

import SwiftUI
import UIKit
import Darwin

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
    /// The last Wine log's lines about an EA game's activation (EAActivationTrace).
    private var eaTrace: [String] = []
    /// The programs the last session started (SessionProgramsTrace).
    private var programsTrace: [String] = []
    /// Where the last Windows exception happened (CrashLocation).
    private var crashLocation: String?
    private static var lastLauncherIsEA: Bool {
        (UserDefaults.standard.string(forKey: "diagnostics.lastLauncher") ?? "").hasPrefix("EA")
    }

    static var wineLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("madeira-log.txt", isDirectory: false)
    }

    /// Size and date of the logs at the last read: an unchanged set is not read again.
    private var lastScanStamp: String?

    private static func stamp(_ urls: [URL]) -> String {
        urls.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.lastPathComponent):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    func scan(force: Bool = false) async {
        guard !isScanning else { return }
        let wineURL = Self.wineLogURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let appURLs = [AppLog.rotatedURL, AppLog.fileURL].compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        hasWineLog = wineURL != nil
        hasAppLog = !appURLs.isEmpty
        let stamp = Self.stamp(appURLs + [wineURL].compactMap { $0 })
        if !force, stamp == lastScanStamp { return }
        isScanning = true
        defer { isScanning = false }
        let steamSession = UserDefaults.standard.bool(forKey: "session.lastWasSteam")
        let eaSession = Self.lastLauncherIsEA
        let generation = scanGeneration
        // The reads run side by side: the app log, the Wine log's bugs, the native
        // diagnosis and the traces each took their turn before (a 15 MB Wine log made
        // the list wait several seconds).
        async let appIssues = Task.detached(priority: .userInitiated) { () -> [LogIssue] in
            let appText = appURLs.compactMap { try? WineLogClipboard.read(from: $0).text }.joined(separator: "\n")
            return LogIssueScanner.scan(appText, source: .app, steamSession: steamSession)
        }.value
        async let wineIssues = Task.detached(priority: .userInitiated) { () -> ([LogIssue], String) in
            guard let wineURL, let text = try? WineLogClipboard.read(from: wineURL).text else {
                return ([], MissingModuleScanner.summary(nil))
            }
            return (LogIssueScanner.scan(text, source: .wine, steamSession: steamSession), MissingModuleScanner.summary(text))
        }.value
        async let diagnosis = Task.detached(priority: .userInitiated) { () -> Int32 in
            wineURL.map { url in url.path.withCString { ideck_wine_log_diagnose($0) } } ?? 0
        }.value
        async let traces = Task.detached(priority: .userInitiated) { () -> ([String], [String], String?) in
            let trace = eaSession ? (wineURL.map { EAActivationTrace.extract(from: $0) } ?? []) : []
            let programs = wineURL.map { SessionProgramsTrace.extract(from: $0) } ?? []
            return (trace, programs, wineURL.flatMap { CrashLocation.find(in: $0) })
        }.value
        let (app, wine, code, extra) = await (appIssues, wineIssues, diagnosis, traces)
        let result = ((app + wine.0).sorted { $0.severity > $1.severity }, code, wine.1, extra.0, extra.1, extra.2)
        // Clearing logs while a read is in flight must not restore stale bugs.
        guard generation == scanGeneration, !Task.isCancelled else { return }
        lastScanStamp = stamp
        issues = Self.liveJITIssues() + result.0
        wineFinding = Self.finding(for: result.1)
        missingModules = result.2
        eaTrace = result.3
        programsTrace = result.4
        crashLocation = result.5
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
        UIPasteboard.general.string = PrivacyRedactor.redact(report(for: [issue]))
        notice = tr("Bug copied to the clipboard.")
    }

    /// "Copy all bugs": the whole report as a .txt file (copyReportFile).
    func copyAll() { copyReportFile() }

    /// The whole report (header, every bug and the evidence sections) as a .txt file.
    func copyReportFile() {
        do {
            try WineLogClipboard.copyText(report(for: issues), named: "iDeck-bug-report.txt")
            notice = tr("Bug report copied as a .txt file.")
        } catch {
            notice = tr("Could not copy the bug report.")
        }
    }

    func copyWineLog() {
        guard let url = Self.wineLogURL else { return }
        Task {
            do {
                try await WineLogClipboard.copyFile(from: url)
                notice = tr("Wine log copied as a .txt file.")
            } catch {
                notice = tr("Could not copy Wine log.")
            }
        }
    }

    var hasFailedWineLog: Bool {
        SystemCoordinator.failedWineLogURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func copyFailedWineLog() {
        guard let url = SystemCoordinator.failedWineLogURL else { return }
        Task {
            do {
                try await WineLogClipboard.copyFile(from: url, name: "Wine-log-failed-launch")
                notice = tr("Wine log of the failed launch copied as a .txt file.")
            } catch {
                notice = tr("Could not copy Wine log.")
            }
        }
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
    /// Every store through its StoreProvider: the EA app's and Ubisoft's downloads
    /// were not counted before.
    static var downloadsOrTransfersActive: Bool {
        StoreProviders.anyDownloadRunning
    }

    /// Clears every log the bug list reads: iDeck's own log and the last
    /// Wine log. Live JIT state is checked again, not cleared.
    func clearLogs() {
        scanGeneration += 1
        lastScanStamp = nil
        AppLog.clear()
        if let wine = Self.wineLogURL {
            try? FileManager.default.removeItem(at: wine)
        }
        if let failed = SystemCoordinator.failedWineLogURL {
            try? FileManager.default.removeItem(at: failed)
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
        let currentMiB = ResourceGovernor.footprintMiB()
        let peakMiB = defaults.object(forKey: "diagnostics.sessionPeakMiB") as? Int
        let physical = ProcessInfo.processInfo.physicalMemory / 1_048_576
        let poolSetting = defaults.object(forKey: "wineJITPoolMiB") as? Int ?? 0
        let pool = poolSetting > 0 ? "\(poolSetting) MB" : "automatic"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let free = (try? documents?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return [
            "Build: commit \(runtime["sourceCommit"] as? String ?? "unknown"), graphics \(MadeiraBundleIdentity.graphicsProfile)",
            "Memory: \(physical) MiB physical, \(ResourceGovernor.availableMiB()) MiB still allowed by iOS",
            "iDeck RAM now: " + (currentMiB >= 0 ? "\(currentMiB) MiB" : "unavailable"),
            (defaults.bool(forKey: "diagnostics.kernelPeak") ? "Last game session, iOS peak iDeck RAM: " : "Last game session, highest sampled iDeck RAM: ") + (peakMiB.map { "\($0) MiB" } ?? "unavailable"),
            "Memory+: increased limit \(name(MemoryPlus.increasedLimit)), extended addressing \(name(MemoryPlus.extendedAddressing)) (\(AddressSpaceCheck.diagnostics))",
            "JIT: method \(defaults.string(forKey: SystemCoordinator.jitMethodKey) ?? "stikdebug"), pool \(pool)",
            "Windows runtime: x64 \(MadeiraRuntime.installed("wine-x64") ? "installed" : "missing"), x86 \(MadeiraRuntime.installed("wine-x86") ? "installed" : "missing")",
            "Device language: \(Locale.preferredLanguages.first ?? "unknown")"
                + (free.map { ", storage free: \($0 / 1_073_741_824) GB" } ?? ""),
        ] + sessionMemoryLines
    }

    /// The last sessions' memory records and the last game's learned profile.
    static var sessionMemoryLines: [String] {
        var lines = SessionMemory.entries().suffix(5).map { "Session: " + $0.line }
        if let game = SessionMemory.entries().last?.game, let learned = GameCompatibility.report(game) {
            lines.append("Compatibility: " + learned)
        }
        return lines
    }

    /// A paste-ready report: device, app build and the selected problems.
    private func report(for selected: [LogIssue]) -> String {
        PrivacyRedactor.register(SteamSignIn.accountName)
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
        let launches = LaunchReport.report
        if !launches.isEmpty {
            lines.append("Recent launches (newest last):")
            lines += launches.split(separator: "\n").map { "  " + $0 }
        }
        if let deps = UserDefaults.standard.string(forKey: DependencyCheck.reportKey) {
            lines.append("DLL check: " + deps)
        }
        lines.append("Stores:")
        lines += StoreProviders.summary.map { "  " + $0 }
        lines.append("Resource Governor: " + ResourceDomains.describe(ResourceDomains.current))
        let transitions = SessionLifecycle.shared.recent
        if !transitions.isEmpty {
            lines.append("Session states (oldest first):")
            lines += transitions.map { "  " + $0 }
        }
        let benchmarks = BenchmarkSession.summaryLines()
        if !benchmarks.isEmpty {
            lines.append("Benchmarks (newest first):")
            lines += benchmarks.map { "  " + $0 }
        }
        var evidence: [String] = []
        if Self.lastLauncherIsEA, let facts = UserDefaults.standard.string(forKey: EALibrary.licenceFactsKey) {
            lines.append("EA licence: " + facts)
            if let check = UserDefaults.standard.string(forKey: EALibrary.hashCheckKey) {
                lines.append("EA hash check: " + check)
            }
            lines.append("EA licence files: " + EAPrefixEvidence.licenceFiles(drive: EALibrary.drive))
            if selected.contains(where: { $0.line.contains("ActivationUI.exe") }) {
                lines.append("EA: the game started ActivationUI.exe, EA's activation window: it did not accept the licence on disk.")
            }
            if !eaTrace.isEmpty {
                evidence += ["", "EA activation trace (Wine log, oldest first):"] + eaTrace
            }
            let logs = EAPrefixEvidence.originLogs(drive: EALibrary.drive)
            if !logs.isEmpty {
                evidence += ["", "EA's own logs (C:\\ProgramData\\Origin\\Logs, newest first):"] + logs
            }
        }
        let defaults = UserDefaults.standard
        if let end = defaults.string(forKey: SystemCoordinator.SessionOutcome.endKey) {
            let stage = defaults.string(forKey: SystemCoordinator.SessionOutcome.stageKey) ?? "unknown"
            lines.append("Last session: " + (end == SystemCoordinator.SessionOutcome.running ? "still running" : "ended: " + end)
                         + " | last stage reached: " + stage)
        }
        if (defaults.string(forKey: "diagnostics.lastLauncher") ?? "") == "Steam",
           let prerequisites = defaults.string(forKey: DockInstallScripts.prerequisitesKey) {
            lines.append("Steam prerequisites (last run): " + prerequisites)
        }
        if let crashLocation { lines.append("Crash location: " + crashLocation) }
        if let missingModules { lines.append("Missing DLLs: " + missingModules) }
        if let wineFinding { lines.append("Diagnosis: " + wineFinding) }
        if !programsTrace.isEmpty {
            evidence += ["", "Programs the last session started (Wine log, oldest first):"] + programsTrace
        }
        lines.append("")
        lines += selected.map(\.copyText)
        lines += evidence
        return lines.joined(separator: "\n")
    }
}
