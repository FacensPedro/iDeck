import SwiftUI
import Metal
import Darwin

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

    func sample() {
        let uptime = ProcessInfo.processInfo.systemUptime
        secondsSinceLaunch = max(0, uptime - startedAt)
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
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
        if let device = metalDevice {
            gpuMemory = "\(device.currentAllocatedSize / (1024 * 1024)) MB"
        }
        previousUptime = uptime
    }
}

struct GameSessionView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var metrics = GameRuntimeMetrics()
    @State private var showActiveWineAlert = false
    @State private var closeRequested = false

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
        if status == "Running" || status == "Steam Running" {
            if metrics.receivedNewFrames {
                let recentlyReady = metrics.secondsSinceLaunch - (metrics.firstFrameAt ?? 0) < 2.5
                return recentlyReady ? (1.0, "First Metal frame displayed") : nil
            }
            return (0.90, "Waiting for the first game frame")
        }
        return nil
    }
    private var wineLogURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent("madeira-log.txt", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let requested = WindowsRendererView.requestedSize
                let fitted = RuntimeConfiguration.fittedSize(content: requested ?? geometry.size, available: geometry.size)
                WindowsRendererView()
                    .frame(width: fitted.width, height: fitted.height)
                    .clipped()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack(alignment: .top) {
                    Button(action: {
                        if ideck_wineprocess_running() {
                            closeRequested = ideck_wineprocess_request_close()
                            showActiveWineAlert = true
                        } else {
                            coordinator.setWindowsStatus("Windows Ready")
                            presentationMode.wrappedValue.dismiss()
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .padding(8)
                    }
                    .accessibilityLabel("Close Wine session")
                    Spacer()
                    if coordinator.isHUDEnabled {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("FPS: \(metrics.fps)  CPU: \(metrics.cpu)")
                            Text("Metal: \(metrics.gpuMemory)  GPU %: N/D")
                            Text("GPU % não é disponibilizada por APIs públicas do iPadOS.")
                                .font(.system(size: 9))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    }
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
                        if let logURL = wineLogURL {
                            ShareLink(item: logURL) {
                                Label(tr("Share Wine log"), systemImage: "square.and.arrow.up")
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
                } else if coordinator.windowsStatus == "Running" &&
                            metrics.secondsSinceLaunch >= 15 && !metrics.receivedNewFrames {
                    Text(tr("Wine started, but no new Metal frames were detected. The game may still be loading."))
                        .foregroundColor(.yellow)
                        .padding(10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
        }
        .onAppear {
            WineInputBridge.shared.startBridging()
            metrics.sample()
        }
        .onReceive(tick) { _ in
            metrics.sample()
            coordinator.refreshWindowsSessionHealth()
            if closeRequested && !ideck_wineprocess_running() {
                closeRequested = false
                coordinator.setWindowsStatus("Windows Ready")
                presentationMode.wrappedValue.dismiss()
            }
        }
        .alert("Close Wine session", isPresented: $showActiveWineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(closeRequested
                ? "A Windows close request (Alt+F4) was sent. Save and confirm the exit inside the game. The Metal display stays attached until Wine stops."
                : "The Wine keyboard queue is not available. Close the game using its own menu. The display stays attached while Wine runs; if it is frozen, close iDeck from the app switcher.")
        }
    }
}
