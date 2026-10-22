import SwiftUI
import UniformTypeIdentifiers

enum AppMode: String, CaseIterable, Identifiable {
    case windows = "Windows"
    case liveContainer = "LiveContainer"

    var id: String { rawValue }

    /// Name of an optional image set in Assets.xcassets holding the official mark of the engine
    /// behind this mode (drop the files in as "MadeiraLogo" / "LiveContainerSymbol").
    var brandAsset: String {
        switch self {
        case .windows: return "MadeiraLogo"
        case .liveContainer: return "LiveContainerSymbol"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .windows: return "window.casement"
        case .liveContainer: return "cube.box.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .windows: return tr("Run Windows apps and Steam through Wine")
        case .liveContainer: return tr("Run iOS apps inside iDeck")
        }
    }
}

/// Shows the image set `assetName` when it exists in the asset catalog, an SF Symbol otherwise.
struct BrandMark: View {
    let assetName: String
    let fallbackSymbol: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isWide {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 280)
                    Divider().background(Color.white.opacity(0.1))
                    if isHome {
                        homeScreen
                    } else {
                        detail
                    }
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    if isHome {
                        homeScreen
                    } else {
                        Picker(tr("Mode"), selection: $mode) {
                            ForEach(AppMode.allCases) { Text(tr($0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .onChange(of: mode) { _ in isHome = false }
                        detail
                    }
                }
            }
        }
        .onAppear {
            coordinator.refreshJITStatus()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { coordinator.refreshJITStatus() }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(coordinator: coordinator)
        }
        .fileImporter(
            isPresented: $isDocumentPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                coordinator.launchWindowsExecutable(at: url)
            }
        }
        .onChange(of: coordinator.windowsStatus) { status in
            if status == "Windows Ready" { isWindowsWorkspacePresented = true }
        }
        .fullScreenCover(isPresented: $isWindowsWorkspacePresented) {
            WindowsWorkspaceView(
                coordinator: coordinator,
                onBack: { isWindowsWorkspacePresented = false },
                onAddExecutable: { isDocumentPickerPresented = true }
            )
        }
        .fullScreenCover(isPresented: Binding<Bool>(
            get: { coordinator.windowsStatus == "Steam Running" || coordinator.windowsStatus == "Running" },
            set: { _ in coordinator.setWindowsStatus("Windows Ready") }
        )) {
            GameSessionView(coordinator: coordinator)
        }
    }

    // MARK: Layout pieces

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image("IDeckLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

            Button(action: { isHome = true }) {
                Label(tr("Home"), systemImage: "house.fill")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(isHome ? Color.blue.opacity(0.35) : cardColor)
                    .cornerRadius(12)
            }

            VStack(spacing: 8) {
                ForEach(AppMode.allCases) { item in
                    Button(action: { mode = item; isHome = false }) {
                        HStack(spacing: 12) {
                            BrandMark(assetName: item.brandAsset, fallbackSymbol: item.fallbackSymbol)
                                .frame(width: 28, height: 28)
                            Text(tr(item.rawValue))
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(12)
                        .background(mode == item ? Color.blue.opacity(0.35) : cardColor)
                        .cornerRadius(12)
                    }
                }
            }

            Spacer()
            statusPills(vertical: true)
            Button(action: { isSettingsPresented = true }) {
                Label(tr("Settings"), systemImage: "gearshape.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(cardColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07).ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Image("IDeckLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 44)
            Spacer()
            Button(action: { isSettingsPresented = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(cardColor)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func statusPills(vertical: Bool) -> some View {
        let pills = Group {
            StatusPill(isActive: coordinator.isJITEnabled, label: "JIT")
            StatusPill(isActive: coordinator.isContainerReady, label: tr("Container"))
        }
        return Group {
            if vertical {
                VStack(alignment: .leading, spacing: 8) { pills }
            } else {
                HStack(spacing: 12) { pills }
            }
        }
    }
 
    private var homeScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("IDeckLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: isWide ? 240 : 190)
                    .padding(.bottom, 6)
                Text(tr("Home"))
                    .font(.system(size: isWide ? 34 : 28, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text(tr("Choose a mode to continue"))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                ForEach(AppMode.allCases) { item in
                    Button {
                        mode = item
                        isHome = false
                    } label: {
                        HStack(spacing: 16) {
                            BrandMark(assetName: item.brandAsset, fallbackSymbol: item.fallbackSymbol)
                                .frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tr(item.rawValue))
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(item.subtitle)
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.gray)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardColor)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, isWide ? 32 : 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if !isWide { statusPills(vertical: false) }

                switch mode {
                case .windows: windowsActions
                case .liveContainer: liveContainerActions
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, isWide ? 32 : 16)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            BrandMark(assetName: mode.brandAsset, fallbackSymbol: mode.fallbackSymbol)
                .frame(width: isWide ? 120 : 88, height: isWide ? 120 : 88)
            Text(tr(mode.rawValue))
                .font(.system(size: isWide ? 34 : 28, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
            Text(mode.subtitle)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            Text(trStatus(mode == .windows ? coordinator.windowsStatus : coordinator.liveContainerStatus))
                .font(.footnote)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            if coordinator.prefixInstaller.isInstalling {
                VStack(spacing: 6) {
                    ProgressView(value: Double(coordinator.prefixInstaller.progress))
                        .tint(.white)
                        .frame(maxWidth: 240)
                    Text(tr("Installing Windows environment..."))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 16)]
    }

    private func actionButton(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(cardColor)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }

    private var windowsActions: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            actionButton(tr("Start Windows Environment"), symbol: "power") {
                coordinator.forceJITAndStartWindows()
            }
        }
    }

    private var liveContainerActions: some View {
        VStack(spacing: 16) {
            actionButton(tr("Start LiveContainer"), symbol: "power") {
                coordinator.forceJITAndStartLiveContainer()
            }
            GuestAppListView(coordinator: coordinator)
                .frame(height: 340)
                .background(Color(red: 0.1, green: 0.1, blue: 0.1))
                .cornerRadius(12)
        }
    }
}

struct StatusPill: View {
    let isActive: Bool
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .cornerRadius(16)
    }
}

struct WindowsWorkspaceView: View {
    @ObservedObject var coordinator: SystemCoordinator
    let onBack: () -> Void
    let onAddExecutable: () -> Void

    @State private var isSettingsPresented = false
    @State private var showSteamIntegrationAlert = false
    private let panelColor = Color(red: 0.12, green: 0.12, blue: 0.12)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Label(tr("Back"), systemImage: "chevron.left")
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text(tr("Windows"))
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button { isSettingsPresented = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 42, height: 42)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Game Library"))
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text(tr("Steam games and imported Windows installers"))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button {
                        showSteamIntegrationAlert = true
                    } label: {
                        Label(tr("Connect Steam"), systemImage: "link")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
                .padding(16)

                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 42))
                        .foregroundColor(.gray)
                    Text(tr("Steam library integration is not configured"))
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text(tr("This iDeck build does not include Madeira's FEX, Wine ARM64EC, DXMT and Steam Dock runtime. Opening Steam's website does not connect an account or load games."))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Button(action: onAddExecutable) {
                        Label(tr("Install a Windows .exe"), systemImage: "square.and.arrow.down")
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(panelColor)
                            .cornerRadius(12)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(coordinator: coordinator)
        }
        .alert(tr("Steam integration unavailable"), isPresented: $showSteamIntegrationAlert) {
            Button(tr("OK"), role: .cancel) { }
        } message: {
            Text(tr("Steam account sign-in and library loading require Madeira's runtime integration, which is not included in this build yet."))
        }
        .preferredColorScheme(.dark)
    }
}
