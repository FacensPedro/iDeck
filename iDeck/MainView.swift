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
        if UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .resizable()
                .scaledToFit()
                .foregroundColor(.white)
        }
    }
}

struct MainView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @StateObject private var inputManager = InputManager.shared
    @State private var mode: AppMode = .windows
    @State private var isHome = true
    @State private var isDocumentPickerPresented = false
    @State private var isSettingsPresented = false
    @State private var isWindowsWorkspacePresented = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue // re-renders on change

    private let cardColor = Color(red: 0.15, green: 0.15, blue: 0.15)

    private var isWide: Bool { horizontalSizeClass == .regular }
    private var actionsEnabled: Bool { coordinator.isJITEnabled && coordinator.isContainerReady }

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
                        .onChange(of: mode) { selectedMode in selectMode(selectedMode) }
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
            if status == "Windows Ready" && mode == .windows && !isHome { isWindowsWorkspacePresented = true }
        }
        .fullScreenCover(isPresented: $isWindowsWorkspacePresented) {
            WindowsWorkspaceView(
                coordinator: coordinator,
                onBack: { isWindowsWorkspacePresented = false; isHome = true },
                onAddExecutable: { isDocumentPickerPresented = true }
            )
        }
        .fullScreenCover(isPresented: Binding<Bool>(
            get: { !isHome && mode == .windows && (coordinator.windowsStatus == "Steam Running" || coordinator.windowsStatus == "Running") },
            set: { _ in coordinator.setWindowsStatus("Windows Ready") }
        )) {
            GameSessionView(coordinator: coordinator)
        }
    }

    private func selectMode(_ selectedMode: AppMode) {
        mode = selectedMode
        isHome = false
        guard selectedMode == .windows else { return }
        if coordinator.windowsStatus == "Windows Ready" {
            isWindowsWorkspacePresented = true
        } else {
            coordinator.forceJITAndStartWindows()
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
                    Button(action: { selectMode(item) }) {
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
                        selectMode(item)
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


struct SteamGameArtworkView: View {
    let game: SteamAppInfo
    @State private var candidateIndex = 0

    private var candidates: [URL] {
        var urls: [URL] = []
        func append(_ url: URL?) {
            if let url, !urls.contains(url) { urls.append(url) }
        }
        if let asset = game.libraryCapsule,
           asset.utf8.count <= 256,
           !asset.isEmpty,
           !asset.hasPrefix("/"),
           !asset.contains(".."),
           asset.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) {
            append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\\(game.appID)/\\(asset)"))
        }
        append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\\(game.appID)/library_600x900.jpg"))
        if let parentID = game.parentID {
            append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\\(parentID)/library_600x900.jpg"))
        }
        if let header = game.headerImage,
           header.utf8.count <= 256,
           !header.isEmpty,
           !header.hasPrefix("/"),
           !header.contains(".."),
           header.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) {
            append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\\(game.appID)/\\(header)"))
        }
        return urls
    }

    var body: some View {
        AsyncImage(url: candidateIndex < candidates.count ? candidates[candidateIndex] : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if phase.error != nil {
                Image(systemName: "gamecontroller.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .foregroundColor(.gray)
                    .onAppear {
                        if candidateIndex + 1 < candidates.count { candidateIndex += 1 }
                    }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView().tint(.gray)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: game.appID) { candidateIndex = 0 }
        .accessibilityLabel(game.name)
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
    @State private var isSteamSignInPresented = false
    @State private var searchText = ""
    @StateObject private var steamLibrary = SteamOwnedGamesModel()
    @Environment(\.openURL) private var openURL
    private let panelColor = Color(red: 0.12, green: 0.12, blue: 0.12)

    private var filteredSteamGames: [SteamAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return steamLibrary.games }
        return steamLibrary.games.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.appID).contains(query)
        }
    }

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
                        isSteamSignInPresented = true
                    } label: {
                        Label(tr(coordinator.isSteamConnected ? "Steam connected" : "Connect Steam"), systemImage: coordinator.isSteamConnected ? "checkmark.circle.fill" : "link")
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
                    Image(systemName: coordinator.isSteamConnected ? "checkmark.circle.fill" : "gamecontroller")
                        .font(.system(size: 42))
                        .foregroundColor(coordinator.isSteamConnected ? .green : .gray)
                    Text(tr(coordinator.isSteamConnected ? "Connected to Steam" : "Connect Steam to continue"))
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    if coordinator.isSteamConnected {
                        Text(tr("Signed in as %@",
                                SteamSignIn.accountName ?? tr("Connected")))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Text(tr("The owned-games list is fetched from Steam. Launching Windows games still requires the Madeira native runtime."))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        libraryContent
                    } else {
                        Text(tr("Sign in directly with Steam. iDeck does not store your password; the sign-in token is saved in this device's Keychain."))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Text(tr("Sign in to load the Steam game library. Launching Windows games still requires the Madeira native runtime."))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
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
        .sheet(isPresented: $isSteamSignInPresented) {
            SteamSignInView()
        }
        .task(id: coordinator.isSteamConnected) {
            if coordinator.isSteamConnected {
                await steamLibrary.refresh()
            } else {
                steamLibrary.disconnect()
            }
        }
        .preferredColorScheme(.dark)
    }

    
    @ViewBuilder
    private var libraryContent: some View {
        if steamLibrary.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text(tr("Loading Steam library..."))
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 8)
        } else if let error = steamLibrary.errorMessage {
            Text(tr(error))
                .font(.footnote)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
            Button {
                Task { await steamLibrary.refresh() }
            } label: {
                Label(tr("Refresh library"), systemImage: "arrow.clockwise")
                    .foregroundColor(.white)
            }
            .padding(.vertical, 6)
        } else if !steamLibrary.games.isEmpty {
            VStack(spacing: 12) {
                HStack {
                    Text(tr("Owned games: %d", steamLibrary.games.count))
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        Task { await steamLibrary.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(panelColor)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(tr("Refresh library"))
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField(tr("Search your games"), text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(panelColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if filteredSteamGames.isEmpty {
                    Text(tr("No games match this search"))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.vertical, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredSteamGames, id: \.appID) { game in
                                HStack(spacing: 12) {
                                    SteamGameArtworkView(game: game)
                                        .frame(width: 64, height: 88)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(game.name.isEmpty ? tr("Untitled Steam app") : game.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                        Text(tr("App ID: %u", game.appID))
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Text(game.oslist.localizedCaseInsensitiveContains("windows") ? tr("Windows") : tr("Windows support not listed"))
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer(minLength: 4)
                                    Button {
                                        if let url = URL(string: "https://store.steampowered.com/app/\\(game.appID)/") {
                                            openURL(url)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.title3)
                                            .foregroundColor(.white)
                                            .frame(width: 38, height: 38)
                                            .background(Color.blue.opacity(0.8))
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                    }
                                    .accessibilityLabel(tr("Open Steam Store"))
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(panelColor)
                                .cornerRadius(10)
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                }
                Text(tr("Direct Steam game downloads need the Madeira downloader and Windows runtime, which are not integrated yet."))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
        }        } else {
            Text(tr("No owned games found yet."))
                .font(.subheadline)
                .foregroundColor(.gray)
            Button {
                Task { await steamLibrary.refresh() }
            } label: {
                Label(tr("Refresh library"), systemImage: "arrow.clockwise")
                    .foregroundColor(.white)
            }
            .padding(.vertical, 6)
        }
    }
}
