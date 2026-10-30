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
    @StateObject private var metrics = GameRuntimeMetrics()
    @AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false
    @State private var recentWineLogFinding: String?
    @State private var logCopyMessage: String?
    @State private var isCopyingWineLog = false

    private var gameLoading: (progress: Double, stage: String)? {
        let status = coordinator.windowsStatus
        if status == VisualCRuntimeBootstrap.installStatus {
            return (0.15, "Preparing Microsoft Visual C++")
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
            if metrics.receivedNewFrames {
                let recentlyReady = metrics.secondsSinceLaunch - (metrics.firstFrameAt ?? 0) < 2.5
                return recentlyReady ? (1.0, "First Metal frame displayed") : nil
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
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent("madeira-log.txt", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        switch diagnosis {
        case 1:
            recentWineLogFinding = "Last Wine log indicates an executable JIT allocation or mapping failure."
        case 2:
            recentWineLogFinding = "Last Wine log indicates that executable memory permissions were denied."
        case 3:
            recentWineLogFinding = "Last Wine log indicates the Windows process ran out of memory."
        case 4:
            recentWineLogFinding = "Last Wine log indicates a Windows program memory access violation."
        case 5:
            recentWineLogFinding = "Last Wine log indicates a missing or incompatible DLL."
        case 6:
            recentWineLogFinding = "A 32-bit Windows program could not reserve its WoW64 address window. The iOS device's virtual address space is insufficient for the current Madeira memory policy."
        case 7:
            recentWineLogFinding = "Wine/FEX encountered an unhandled native ARM64EC exception (x18 handler) and terminated with NTSTATUS 0xC000001D. This is a runtime compatibility failure, not proof of a missing game DLL."
        default:
            recentWineLogFinding = nil
        }
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                WindowsRendererView()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea(edges: .bottom)

            if let preset = coordinator.activeWindowsProfile?.touchControlPreset,
               preset != "off", !coordinator.isClosingWindowsSession {
                VStack {
                    Spacer()
                    IDeckTouchGamepadOverlay(preset: preset)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 18)
                }
                .transition(.opacity)
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
                    .accessibilityLabel(tr("Close Wine and return to Steam library"))
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
                    coordinator.windowsStatus == VisualCRuntimeBootstrap.installStatus {
                    HStack {
                        ProgressView()
                        Text(coordinator.windowsStatus == VisualCRuntimeBootstrap.installStatus
                            ? tr("Installing Microsoft Visual C++...")
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
                        Text(tr("Wine started, but no game frame was detected. The selected executable may require Steam, a different working folder or missing runtime DLLs."))
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
        .onAppear {
            WineInputBridge.shared.startBridging()
            metrics.sample(collectPerformance: showGamePerformanceOverlay)
            updateRecentWineLogFinding()
        }
        .onChange(of: coordinator.windowsStatus) { _, _ in
            updateRecentWineLogFinding()
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
               metrics.receivedNewFrames {
                // The loader thread being alive is insufficient. Require a
                // native Metal presentation before promoting game readiness.
                SteamLog.event("[steam-start] first Metal frame detected after Wine startup")
                coordinator.setWindowsStatus("Running")
            }
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
            Button(tr("Return to Game"), role: .cancel) { coordinator.cancelWindowsSessionClose() }
        } message: {
            Text(tr(coordinator.windowsCloseWarning ?? ""))
        }
    }
}

private struct IDeckVirtualGamepadState {
    var buttons: UInt16 = 0
    var lx: Int16 = 0
    var ly: Int16 = 0
    var rx: Int16 = 0
    var ry: Int16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
}

private struct IDeckTouchGamepadOverlay: View {
    let preset: String
    @State private var pad = IDeckVirtualGamepadState()

    private func publish() {
        ideck_touch_gamepad_set_state(pad.buttons, pad.lx, pad.ly, pad.rx, pad.ry,
                                     pad.leftTrigger, pad.rightTrigger)
    }

    private func setButton(_ bit: UInt16, pressed: Bool) {
        if pressed { pad.buttons |= bit }
        else { pad.buttons &= ~bit }
        publish()
    }

    private func control(_ label: String, bit: UInt16) -> some View {
        Text(label)
            .font(.caption.bold())
            .foregroundColor(.white)
            .frame(width: 43, height: 43)
            .background(Color.blue.opacity(pad.buttons & bit == 0 ? 0.35 : 0.8),
                        in: Circle())
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pad.buttons & bit == 0 { setButton(bit, pressed: true) }
                    }
                    .onEnded { _ in setButton(bit, pressed: false) }
            )
    }

    private func analog(_ right: Bool) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let x = CGFloat(right ? pad.rx : pad.lx) / 32767.0
            let y = -CGFloat(right ? pad.ry : pad.ly) / 32767.0
            ZStack {
                Circle().stroke(Color.white.opacity(0.5), lineWidth: 2)
                Circle().fill(Color.white.opacity(0.65))
                    .frame(width: 29, height: 29)
                    .offset(x: x * width * 0.3, y: y * height * 0.3)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = (value.location.x - width / 2) / max(1, width * 0.35)
                        let dy = (height / 2 - value.location.y) / max(1, height * 0.35)
                        let axisX = Int16((min(1, max(-1, dx)) * 32767).rounded())
                        let axisY = Int16((min(1, max(-1, dy)) * 32767).rounded())
                        if right { pad.rx = axisX; pad.ry = axisY }
                        else { pad.lx = axisX; pad.ly = axisY }
                        publish()
                    }
                    .onEnded { _ in
                        if right { pad.rx = 0; pad.ry = 0 }
                        else { pad.lx = 0; pad.ly = 0 }
                        publish()
                    }
            )
        }
        .frame(width: 98, height: 98)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if preset == "xbox" {
                analog(false)
                VStack(spacing: 5) {
                    control("↑", bit: 0x0001)
                    HStack(spacing: 4) {
                        control("←", bit: 0x0004)
                        control("→", bit: 0x0008)
                    }
                    control("↓", bit: 0x0002)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    control("LB", bit: 0x0100)
                    control("Start", bit: 0x0010)
                }
                HStack(spacing: 4) {
                    control("Y", bit: 0x8000)
                    control("X", bit: 0x4000)
                }
                HStack(spacing: 4) {
                    control("B", bit: 0x2000)
                    control("A", bit: 0x1000)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            ideck_touch_gamepad_set_enabled(1)
            publish()
        }
        .onDisappear {
            ideck_touch_gamepad_set_enabled(0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Touch controls"))
    }
}
