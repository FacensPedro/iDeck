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
            if let baselineFrames, count > baselineFrames { receivedNewFrames = true }
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
                            showActiveWineAlert = true
                        } else {
                            coordinator.setWindowsStatus("Windows Ready")
                            presentationMode.wrappedValue.dismiss()
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 44, height: 44)
                            .padding(8)
                    }
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
                    Text(trStatus(coordinator.windowsStatus))
                        .foregroundColor(.red)
                        .padding(10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
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
        }
        .alert("Wine ainda está executando", isPresented: $showActiveWineAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Feche o jogo pelo próprio Windows antes de sair desta tela. Ocultar a superfície Metal com o Wine ativo pode interromper os gráficos. Se o jogo travou, encerre o iDeck pelo seletor de aplicativos.")
        }
    }
}
