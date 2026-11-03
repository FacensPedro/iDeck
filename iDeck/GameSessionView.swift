import SwiftUI
import Combine
import Metal
import Darwin
import UIKit

private final class GameRuntimeMetrics: ObservableObject {
    @Published private(set) var fps = "N/D"
    @Published private(set) var cpu = "N/D"
    @Published private(set) var gpuMemory = "N/D"
    @Published private(set) var frameCount: UInt64 = 0
    @Published private(set) var secondsSinceLaunch: TimeInterval = 0
    @Published private(set) var presentCounterAvailable = false
    @Published private(set) var receivedNewFrames = false
    @Published private(set) var firstFrameAt: TimeInterval?

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let metalDevice = MTLCreateSystemDefaultDevice()
    private var baselineFrames: UInt64?
    private var previousUptime: TimeInterval?
    private var previousCPU: Double?
    private var previousFrames: UInt64?
    private typealias PresentCount = @convention(c) () -> UInt64

    init() {
        // Capture the in-process present counter when the game session view
        // is created, not at the first one-second timer sample. Otherwise
        // the first and only guest frame can become the baseline and never
        // be acknowledged. Previous Wine sessions may have left a nonzero
        // counter, so do not interpret a raw nonzero count as this game's frame.
        if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                               "madeira_get_present_count") {
            baselineFrames = unsafeBitCast(pointer, to: PresentCount.self)()
        }
    }

    /// Re-arm the render-counter baseline once Valve's LaunchApp succeeds.
    /// Frames produced earlier by Wine's desktop or the Steam loader cannot
    /// count as a successful post-launch Metal presentation.
    func armAfterSteamLaunch() {
        if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_get_present_count") {
            baselineFrames = unsafeBitCast(pointer, to: PresentCount.self)()
            receivedNewFrames = false
            firstFrameAt = nil
        }
    }

    func sample(collectPerformance: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        secondsSinceLaunch = max(0, uptime - startedAt)
        var usage = rusage()
        if collectPerformance && getrusage(RUSAGE_SELF, &usage) == 0 {
            let consumed = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000 +
                Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            if let oldTime = previousUptime, let oldCPU = previousCPU, uptime > oldTime {
                cpu = String(format: "%.0f%%", max(0, (consumed - oldCPU) / (uptime - oldTime) * 100))
            }
            previousCPU = consumed
        }
        if let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_get_present_count") {
            presentCounterAvailable = true
            let count = unsafeBitCast(pointer, to: PresentCount.self)()
            if baselineFrames == nil { baselineFrames = count }
            if let baselineFrames, count > baselineFrames {
                if firstFrameAt == nil { firstFrameAt = secondsSinceLaunch }
                receivedNewFrames = true
            }
            if let oldTime = previousUptime, let oldFrames = previousFrames, uptime > oldTime {
                let delta = count >= oldFrames ? count - oldFrames : 0
                fps = String(format: "%.0f", Double(delta) / (uptime - oldTime))
            }
            frameCount = count
            previousFrames = count
        } else {
            presentCounterAvailable = false
            fps = "N/D"
        }
        if collectPerformance, let device = metalDevice {
            gpuMemory = "\(device.currentAllocatedSize / (1024 * 1024)) MB"
        }
        previousUptime = uptime
    }
}

struct GameSessionView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var metrics = GameRuntimeMetrics()
    @AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false
    @ObservedObject private var inputManager = InputManager.shared
    @State private var recentWineLogFinding: String?
    @State private var logCopyMessage: String?
    @State private var isCopyingWineLog = false
    @State private var showControlsSheet = false

    private var gameLoading: (progress: Double, stage: String)? {
        let status = coordinator.windowsStatus
        if status == VisualCRuntimeBootstrap.installStatus {
            return (0.15, "Preparing Microsoft Visual C++")
        }
        if status == SystemCoordinator.steamComponentsInstallStatus {
            return (0.30, "Installing Steam client components")
        }
        if status == "Installing Steam prerequisites..." {
            return (0.35, coordinator.steamPrerequisiteProgress ?? "Installing Steam game prerequisites")
        }
        if status == "Preparing Wine prefix..." || status == "Preparing Windows Environment..." {
            return (0.20, "Preparing Wine prefix")
        }
        if status == "Launching Steam game..." || status == "Launching Steam client..." ||
           status == "Launching Windows app..." {
            return (0.45, "Starting Wine and FEX")
        }
        if status == "Running" || status == "Steam Running" ||
           status == "Wine started; waiting for game..." {
            if coordinator.currentSteamLaunchUsesDock && !coordinator.dockLaunchAccepted {
                return (0.70, coordinator.steamDockLaunchStage ?? "Starting Madeira Dock")
            }
            if metrics.receivedNewFrames {
                let recentlyReady = metrics.secondsSinceLaunch - (metrics.firstFrameAt ?? 0) < 2.5
                return recentlyReady ? (1.0, "First Metal frame displayed") : nil
            }
            if coordinator.currentSteamLaunchUsesDock {
                return (0.90, "Waiting for a Metal frame after Steam's LaunchApp")
            }
            return (0.90, "Waiting for the first game frame")
        }
        return nil
    }
    private var hasWineProblem: Bool {
        let status = coordinator.windowsStatus
        if status.hasPrefix("Execution Error") { return true }
        if status == "Running" &&
            (!WindowsRendererView.isNativeDisplayLinked || !metrics.presentCounterAvailable) {
            return true
        }
        return (status == "Running" || status == "Wine started; waiting for game...") &&
               metrics.secondsSinceLaunch >= 20 && !metrics.receivedNewFrames
    }

    private var wineLogURL: URL? {
        BugReportModel.wineLogURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func copyWineLog() {
        guard let url = wineLogURL, !isCopyingWineLog else { return }
        isCopyingWineLog = true
        logCopyMessage = nil
        Task {
            let content = await Task.detached(priority: .utility) {
                try? WineLogClipboard.read(from: url)
            }.value
            isCopyingWineLog = false
            guard let content else {
                logCopyMessage = "Could not copy Wine log."
                return
            }
            UIPasteboard.general.string = content.text
            logCopyMessage = content.truncated
                ? "The newest 4 MiB of the Wine log were copied. Share the file for the complete log."
                : "Wine log copied to the clipboard."
        }
    }

    // Based on Madeira's LogSummary, but performs a bounded, privacy-safe
    // native scan only on a launch error rather than parsing a large log on
    // each SwiftUI refresh.
    private func updateRecentWineLogFinding() {
        guard coordinator.windowsStatus.hasPrefix("Execution Error"),
              let url = wineLogURL else {
            recentWineLogFinding = nil
            return
        }
        let diagnosis = url.path.withCString { ideck_wine_log_diagnose($0) }
        recentWineLogFinding = BugReportModel.finding(for: diagnosis)
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Edge to edge: on iPhones the safe area (Dynamic Island, notch,
            // home indicator) would otherwise shrink the game image; the
            // surface mode letterboxes it within the whole screen.
            GeometryReader { geometry in
                WindowsRendererView()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    Button(action: coordinator.requestCloseWindowsSession) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .padding(8)
                    }
                    .disabled(coordinator.isClosingWindowsSession)
                    .accessibilityLabel(tr("Close Wine and return to the library"))
                    Button { showControlsSheet = true } label: {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .padding(.vertical, 8)
                    }
                    .accessibilityLabel(tr("Controls"))
                    // The Metal layer sits directly over the SwiftUI content
                    // outside this top strip. Keep first-frame failures and
                    // shutdown progress VISIBLE even when the drawable is black.
                    if coordinator.isClosingWindowsSession {
                        Text(tr("Closing Wine and wineserver..."))
                            .foregroundColor(.white)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                    } else if !metrics.receivedNewFrames &&
                              (coordinator.windowsStatus == "Wine started; waiting for game..." ||
                               coordinator.windowsStatus == "Running") {
                        Text(tr(metrics.secondsSinceLaunch >= 20
                            ? "No Windows game frame detected. Check the Wine log."
                            : "Waiting for the first Windows game frame..."))
                            .foregroundColor(metrics.secondsSinceLaunch >= 20 ? .yellow : .white)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if hasWineProblem && wineLogURL != nil {
                        Button(action: copyWineLog) {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                        }
                        .disabled(isCopyingWineLog)
                        .accessibilityLabel(tr("Copy Wine log"))
                    }
                    if showGamePerformanceOverlay &&
                        coordinator.windowsStatus == "Running" &&
                        metrics.receivedNewFrames {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("FPS: \(metrics.fps)  CPU: \(metrics.cpu)")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if horizontalSizeClass != .compact {
                                Text("GPU memory (Metal): \(metrics.gpuMemory)")
                                Text("GPU utilization: unavailable on iOS")
                                    .font(.system(size: 9))
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let logCopyMessage {
                    Text(tr(logCopyMessage))
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                }
                if coordinator.isClosingWindowsSession {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(tr("Closing Wine and wineserver..."))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 14)
                }
                if let loading = gameLoading {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(loading.stage)
                            Spacer()
                            Text("\(Int(loading.progress * 100))%")
                                .monospacedDigit()
                        }
                        .font(.system(size: 13, weight: .medium))
                        ProgressView(value: loading.progress, total: 1)
                            .tint(.blue)
                        if !metrics.receivedNewFrames {
                            Text("Startup milestone, not the game's internal loading percentage.")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 14)
                }
                if coordinator.windowsStatus == "Launching Steam game..." ||
                    coordinator.windowsStatus == "Launching Steam client..." ||
                    coordinator.windowsStatus == "Launching Windows app..." ||
                    coordinator.windowsStatus == "Installing Steam prerequisites..." ||
                    coordinator.windowsStatus == VisualCRuntimeBootstrap.installStatus ||
                    coordinator.windowsStatus == SystemCoordinator.steamComponentsInstallStatus {
                    HStack {
                        ProgressView()
                        Text(coordinator.windowsStatus == VisualCRuntimeBootstrap.installStatus
                            ? tr("Installing Microsoft Visual C++...")
                            : coordinator.windowsStatus == SystemCoordinator.steamComponentsInstallStatus
                            ? tr("Installing Steam client components...") + (coordinator.steamComponentsProgress.map { "\n" + tr($0) } ?? "")
                            : tr("Preparing Wine and graphics..."))
                    }
                    .padding(10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                } else if coordinator.windowsStatus.hasPrefix("Visual C++") {
                    Text(trStatus(coordinator.windowsStatus))
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if coordinator.windowsStatus.hasPrefix("Execution Error") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(trStatus(coordinator.windowsStatus))
                            .foregroundColor(.red)
                        if let recentWineLogFinding {
                            Text(tr(recentWineLogFinding))
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        if let logURL = wineLogURL {
                            HStack(spacing: 20) {
                                Button(action: copyWineLog) {
                                    Label(tr("Copy Wine log"), systemImage: "doc.on.doc")
                                }
                                .disabled(isCopyingWineLog)
                                ShareLink(item: logURL) {
                                    Label(tr("Share Wine log"), systemImage: "square.and.arrow.up")
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            Text(tr("Wine logs can contain personal or account information. Review before sharing."))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                } else if coordinator.windowsStatus == "Running" && !WindowsRendererView.isNativeDisplayLinked {
                    Text(tr("Madeira display backend is missing. This build cannot present Windows graphics."))
                        .foregroundColor(.orange)
                        .padding(10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                } else if coordinator.windowsStatus == "Running" && !metrics.presentCounterAvailable {
                    Text(tr("Wine started, but the Metal presentation counter is unavailable. Graphics are not verified."))
                        .foregroundColor(.orange)
                        .padding(10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                } else if (coordinator.windowsStatus == "Wine started; waiting for game..." ||
                           coordinator.windowsStatus == "Running") &&
                           metrics.secondsSinceLaunch >= 20 && !metrics.receivedNewFrames {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(tr(coordinator.isSteamSession
                            ? "Wine started, but no game frame was detected. The selected executable may require Steam, a different working folder or missing runtime DLLs."
                            : "Wine started, but no game frame was detected. The selected executable may need a different working folder or missing runtime DLLs."))
                            .foregroundColor(.yellow)
                        Text(tr("Wine is still active. Check its log before closing the session."))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.75))
                        if let logURL = wineLogURL {
                            ShareLink(item: logURL) {
                                Label(tr("Share Wine log"), systemImage: "square.and.arrow.up")
                            }
                            .font(.subheadline)
                            Text(tr("Wine logs can contain personal or account information. Review before sharing."))
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12)
                }
                Spacer()
            }
        }
        .modifier(WineGamepadEventClaim())
        .sheet(isPresented: $showControlsSheet) { SessionControlsSheet() }
        .onChange(of: showGamePerformanceOverlay) { _, on in
            metrics.sample(collectPerformance: on)
        }
        .onAppear {
            TouchController.shared.sessionStarted()
            WineInputBridge.shared.startBridging()
            metrics.sample(collectPerformance: showGamePerformanceOverlay)
            updateRecentWineLogFinding()
        }
        .onChange(of: coordinator.windowsStatus) { _, _ in
            updateRecentWineLogFinding()
        }
        .onChange(of: coordinator.dockLaunchAccepted) { _, accepted in
            if accepted && coordinator.currentSteamLaunchUsesDock {
                metrics.armAfterSteamLaunch()
            }
        }
        .onReceive(tick) { _ in
            // Wine's GDI compositor may come online after SwiftUI has already
            // laid out the persistent Metal layer. Re-publish the exact
            // viewport each second until the first native frame arrives.
            if coordinator.windowsStatus == "Launching Steam game..." ||
               coordinator.windowsStatus == "Launching Steam client..." ||
               coordinator.windowsStatus == "Launching Windows app..." ||
               coordinator.windowsStatus == "Wine started; waiting for game..." ||
               coordinator.windowsStatus == "Running" {
                WindowsRendererView.refreshNativeDisplay()
            }
            metrics.sample(collectPerformance: showGamePerformanceOverlay)
            if coordinator.windowsStatus == "Wine started; waiting for game..." &&
               metrics.receivedNewFrames &&
               (!coordinator.currentSteamLaunchUsesDock || coordinator.dockLaunchAccepted) {
                // The loader thread being alive is insufficient. Require a
                // native Metal presentation before promoting game readiness.
                SteamLog.event(coordinator.currentSteamLaunchUsesDock
                    ? "[steam-start] first Metal present after Steam LaunchApp (game-window identity not verified)"
                    : "[steam-start] first Metal frame detected after Wine startup")
                coordinator.setWindowsStatus("Running")
            }
            coordinator.pollWindowsSessionClose()
            coordinator.refreshWindowsSessionHealth()
        }
        .onDisappear {
            TouchController.shared.sessionEnded()
            WineInputBridge.shared.stopBridging()
        }
        .alert(tr("Wine did not close"), isPresented: Binding(
            get: { coordinator.windowsCloseWarning != nil },
            set: { if !$0 { coordinator.acknowledgeWindowsCloseWarning() } }
        )) {
            Button(tr("Retry Close")) { coordinator.retryCloseWindowsSession() }
            Button(tr("Keep Waiting")) { coordinator.acknowledgeWindowsCloseWarning() }
            Button(tr("Return to Game"), role: .cancel) { coordinator.cancelWindowsSessionClose() }
        } message: {
            Text(tr(coordinator.windowsCloseWarning ?? ""))
        }
    }
}
