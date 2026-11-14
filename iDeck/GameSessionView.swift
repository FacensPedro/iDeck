import SwiftUI
import Combine
import Metal
import Darwin
import UIKit

/// The session's frame and resource figures, sampled once a second. Only what the
/// screen shows is published, and only when it changes: every published change
/// re-evaluates the whole session view, so a game that runs for an hour should not
/// rebuild it 3,600 times for values nobody sees.
private final class GameRuntimeMetrics: ObservableObject {
    @Published private(set) var fps = "N/D"
    @Published private(set) var cpu = "N/D"
    @Published private(set) var gpuMemory = "N/D"
    /// Published until shortly after the first frame (the loading screen and its
    /// 20-second hint read it); afterwards it is kept without republishing.
    @Published private(set) var secondsSinceLaunch: TimeInterval = 0
    @Published private(set) var presentCounterAvailable = false
    @Published private(set) var receivedNewFrames = false
    @Published private(set) var firstFrameAt: TimeInterval?

    private var elapsed: TimeInterval = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private lazy var metalDevice = MTLCreateSystemDefaultDevice()
    private var baselineFrames: UInt64?
    private var previousUptime: TimeInterval?
    private var previousCPU: Double?
    private var previousFrames: UInt64?
    private typealias PresentCount = @convention(c) () -> UInt64
    /// Madeira's present counter, resolved once (nil in an interface-only build).
    private static let presentCount: PresentCount? =
        NativeSymbol.address("madeira_get_present_count").map { unsafeBitCast($0, to: PresentCount.self) }

    init() {
        // Capture the in-process present counter when the game session view
        // is created, not at the first one-second timer sample. Otherwise
        // the first and only guest frame can become the baseline and never
        // be acknowledged. Previous Wine sessions may have left a nonzero
        // counter, so do not interpret a raw nonzero count as this game's frame.
        baselineFrames = Self.presentCount?()
    }

    /// Re-arm the render-counter baseline once Valve's LaunchApp succeeds.
    /// Frames produced earlier by Wine's desktop or the Steam loader cannot
    /// count as a successful post-launch Metal presentation.
    func armAfterSteamLaunch() {
        guard let count = Self.presentCount?() else { return }
        baselineFrames = count
        if receivedNewFrames { receivedNewFrames = false }
        if firstFrameAt != nil { firstFrameAt = nil }
    }

    /// Seconds since the session view appeared (always current, never published late).
    var secondsSinceStart: TimeInterval { elapsed }

    func sample(collectPerformance: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        elapsed = max(0, uptime - startedAt)
        // The loading screen needs the clock until the "ready" banner is gone.
        if !receivedNewFrames || elapsed - (firstFrameAt ?? elapsed) < 3 {
            secondsSinceLaunch = elapsed
        }
        if collectPerformance {
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 {
                let consumed = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000 +
                    Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
                if let oldTime = previousUptime, let oldCPU = previousCPU, uptime > oldTime {
                    update(\.cpu, String(format: "%.0f%%", max(0, (consumed - oldCPU) / (uptime - oldTime) * 100)))
                }
                previousCPU = consumed
            }
        }
        if let presentCount = Self.presentCount {
            if !presentCounterAvailable { presentCounterAvailable = true }
            let count = presentCount()
            if baselineFrames == nil { baselineFrames = count }
            if let baselineFrames, count > baselineFrames, !receivedNewFrames {
                if firstFrameAt == nil { firstFrameAt = elapsed }
                receivedNewFrames = true
            }
            if collectPerformance, let oldTime = previousUptime, let oldFrames = previousFrames, uptime > oldTime {
                let delta = count >= oldFrames ? count - oldFrames : 0
                update(\.fps, String(format: "%.0f", Double(delta) / (uptime - oldTime)))
            }
            previousFrames = count
        } else {
            if presentCounterAvailable { presentCounterAvailable = false }
            update(\.fps, "N/D")
        }
        if collectPerformance, let device = metalDevice {
            update(\.gpuMemory, "\(device.currentAllocatedSize / (1024 * 1024)) MB")
        }
        previousUptime = uptime
    }

    /// Assigns a published string only when it changes.
    private func update(_ key: ReferenceWritableKeyPath<GameRuntimeMetrics, String>, _ value: String) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
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
    @AppStorage("touchMouseEnabled") private var touchMouseEnabled = true
    @State private var metalFXTurnedOff = false

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
            // The bar goes away with the first frame: secondsSinceLaunch stops being
            // published once frames arrive, so a 2.5 s "displayed" stage never ended.
            if metrics.receivedNewFrames { return nil }
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
            defer { isCopyingWineLog = false }
            do {
                try await WineLogClipboard.copyFile(from: url)
                logCopyMessage = tr("Wine log copied as a .txt file.")
            } catch {
                logCopyMessage = tr("Could not copy Wine log.")
            }
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

    /// MetalFX can leave some games black (Skyrim SE on DXMT presented
    /// nothing with it on, 60 fps with it off). When a MetalFX launch shows
    /// no frame for 75 s, MetalFX is turned off for that game.
    private func disableMetalFXIfNoFrames() {
        guard !metalFXTurnedOff, !metrics.receivedNewFrames, metrics.secondsSinceStart >= 75,
              let active = coordinator.activeWindowsProfile, active.metalFXEnabled,
              coordinator.windowsStatus == "Running" || coordinator.windowsStatus == "Wine started; waiting for game..."
        else { return }
        let store = WindowsLibraryStore()
        var profile = store.profile(for: active.id, title: active.title)
        profile.metalFXEnabled = false
        store.save(profile)
        metalFXTurnedOff = true
        SteamLog.event("[metalfx] no game frame after 75 s with MetalFX; turned off for \(active.id)")
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Edge to edge: on iPhones the safe area (Dynamic Island, notch,
            // home indicator) would otherwise shrink the game image; the
            // surface mode letterboxes it within the whole screen.
            if !coordinator.windowsStatus.hasPrefix("Execution Error") {
                GeometryReader { geometry in
                    WindowsRendererView()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .ignoresSafeArea()
            }

            if touchMouseEnabled {
                TouchMouseView().ignoresSafeArea()
            }

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
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .padding(.vertical, 8)
                    }
                    .accessibilityLabel(tr("Settings"))
                    // The game's Metal surface covers everything below the
                    // top strip, so the startup progress lives up here.
                    if let loading = gameLoading {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(tr(loading.stage))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 6)
                                Text("\(Int(loading.progress * 100))%")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 12, weight: .medium))
                            ProgressView(value: loading.progress, total: 1)
                                .tint(.blue)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 380)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(Text("Startup milestone, not the game's internal loading percentage."))
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 8)
                    }
                    // The Metal layer sits directly over the SwiftUI content
                    // outside this top strip. Keep first-frame failures and
                    // shutdown progress VISIBLE even when the drawable is black.
                    if coordinator.isClosingWindowsSession {
                        Text(tr("Closing Wine and wineserver..."))
                            .foregroundColor(.white)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                    } else if metalFXTurnedOff {
                        Text(tr("The game showed no image with MetalFX, so MetalFX is now off for it. Close the game and open it again."))
                            .foregroundColor(.yellow)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(3)
                    } else if !metrics.receivedNewFrames && StikJITHelper.smallPoolMB > 0 {
                        Text(tr("The JIT pool is only %d MB this time, so heavy games may freeze for about a second now and then. Close iDeck and open it again for a full pool.",
                                StikJITHelper.smallPoolMB))
                            .foregroundColor(.yellow)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(3)
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
                                // iOS gives apps no GPU utilization counter; the frame
                                // time is the honest per-frame load figure.
                                Text("Frame time: \(Int(metrics.fps).map { $0 > 0 ? String(format: "%.1f ms", 1000.0 / Double($0)) : "N/D" } ?? "N/D")")
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
        .sheet(isPresented: $showControlsSheet) { SessionControlsSheet(coordinator: coordinator) }
        .onChange(of: showGamePerformanceOverlay) { _, on in
            metrics.sample(collectPerformance: on)
        }
        .onAppear {
            // Touch is direct: no Windows mouse cursor is drawn.
            TouchMouseCursor.hide()
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
            disableMetalFXIfNoFrames()
            coordinator.pollWindowsSessionClose()
            coordinator.refreshWindowsSessionHealth()
        }
        .onDisappear {
            WineInputBridge.shared.stopBridging()
        }
        .alert(tr("Wine did not close"), isPresented: Binding(
            get: { coordinator.windowsCloseWarning != nil },
            set: { if !$0 { coordinator.acknowledgeWindowsCloseWarning() } }
        )) {
            Button(tr("Retry Close")) { coordinator.retryCloseWindowsSession() }
            Button(tr("Keep Waiting")) { coordinator.acknowledgeWindowsCloseWarning() }
            // As Madeira's "Close Madeira": a game that never handles Alt+F4 holds the
            // in-process Wine thread, which cannot be killed alone; closing iDeck ends it.
            Button(tr("Close iDeck"), role: .destructive) { coordinator.forceCloseIDeck() }
            Button(tr("Return to Game"), role: .cancel) { coordinator.cancelWindowsSessionClose() }
        } message: {
            Text(tr(coordinator.windowsCloseWarning ?? ""))
        }
    }
}
