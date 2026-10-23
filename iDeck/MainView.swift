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
        .onAppear { coordinator.refreshJITStatus() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { coordinator.refreshJITStatus() }
        }
        .sheet(isPresented: $isSettingsPresented) { SettingsView(coordinator: coordinator) }
        .fileImporter(isPresented: $isDocumentPickerPresented, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { coordinator.launchWindowsExecutable(at: url) }
        }
        .onChange(of: coordinator.windowsStatus) { status in
            if status == "Windows Ready" && mode == .windows && !isHome { isWindowsWorkspacePresented = true }
        }
        .fullScreenCover(isPresented: $isWindowsWorkspacePresented) {
            WindowsWorkspaceView(coordinator: coordinator, onBack: { isWindowsWorkspacePresented = false; isHome = true }, onAddExecutable: { isDocumentPickerPresented = true })
        }
        .fullScreenCover(isPresented: Binding<Bool>(
            get: { !isHome && mode == .windows && (coordinator.windowsStatus == "Steam Running" || coordinator.windowsStatus == "Running") },
            set: { _ in coordinator.setWindowsStatus("Windows Ready") }
        )) { GameSessionView(coordinator: coordinator) }
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
            append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.appID)/\(asset)"))
        }
        append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)/library_600x900.jpg"))
        if let parentID = game.parentID {
            append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(parentID)/library_600x900.jpg"))
        }
        if let header = game.headerImage,
           header.utf8.count <= 256,
           !header.isEmpty,
           !header.hasPrefix("/"),
           !header.contains(".."),
           header.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) {
            append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.appID)/\(header)"))
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
    @State private var prefixPath: URL?
    @StateObject private var steamLibrary = SteamOwnedGamesModel()
    @Environment(\.openURL) private var openURL

    private let panelColor = Color(red: 0.105, green: 0.105, blue: 0.115)
    private let secondaryColor = Color(red: 0.16, green: 0.16, blue: 0.17)

    private var filteredSteamGames: [SteamAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return steamLibrary.games }
        return steamLibrary.games.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.appID).contains(query)
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 158), spacing: 14)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(tr("Game Library"))
                                    .font(.system(size: 29, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(tr("Install games from your Steam library"))
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            Spacer(minLength: 8)
                            Button {
                                isSteamSignInPresented = true
                            } label: {
                                Label(tr(coordinator.isSteamConnected ? "Steam connected" : "Connect Steam"),
                                      systemImage: coordinator.isSteamConnected ? "checkmark.circle.fill" : "person.crop.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 11)
                                    .background(Color(red: 0.12, green: 0.35, blue: 0.65))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }

                        if coordinator.isSteamConnected {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundColor(.gray)
                                Text(tr("Signed in as %@",
                                        SteamSignIn.accountName ?? tr("Connected")))
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Spacer()
                                Button {
                                    Task { await steamLibrary.refresh() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .foregroundColor(.white)
                                        .padding(10)
                                        .background(secondaryColor)
                                        .clipShape(Circle())
                                }
                                .accessibilityLabel(tr("Refresh library"))
                            }
                            libraryContent
                            Text(tr("Steam game installation is available. Launching requires the Madeira runtime."))
                                .font(.caption)
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(tr("Connect Steam to continue"), systemImage: "steam")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(tr("Sign in directly with Steam. iDeck does not store your password; the sign-in token is saved in this device's Keychain."))
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Text(tr("Sign in to load the Steam game library."))
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(panelColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Button(action: onAddExecutable) {
                            Label(tr("Install .exe"), systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.vertical, 15)
                                .frame(maxWidth: .infinity)
                                .background(secondaryColor)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(maxWidth: 1000)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity)
                }
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
        .onAppear(perform: resolvePrefixPath)
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
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
                    .background(secondaryColor)
                    .clipShape(Circle())
            }
            .accessibilityLabel(tr("Settings"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if steamLibrary.isLoading {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(tr("Loading Steam library..."))
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(panelColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if let error = steamLibrary.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(tr(error))
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await steamLibrary.refresh() }
                } label: {
                    Label(tr("Refresh library"), systemImage: "arrow.clockwise")
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(secondaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(18)
            .background(panelColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if steamLibrary.games.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 34))
                    .foregroundColor(.gray)
                Text(tr("No owned games found yet."))
                    .font(.headline)
                    .foregroundColor(.white)
                Text(tr("Check your Steam account and refresh the library."))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await steamLibrary.refresh() }
                } label: {
                    Label(tr("Refresh library"), systemImage: "arrow.clockwise")
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(secondaryColor)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .padding(18)
            .background(panelColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(tr("Owned games: %d", steamLibrary.games.count))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(tr("Windows games"))
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField(tr("Search your games"), text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(panelColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if filteredSteamGames.isEmpty {
                    Text(tr("No games match this search"))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredSteamGames, id: \.appID) { game in
                            gameCard(game)
                        }
                    }
                }
            }
        }
    }

    private func gameCard(_ game: SteamAppInfo) -> some View {
        let progress = steamLibrary.downloadProgress[game.appID]
        let percent = Int(((progress?.fraction ?? 0) * 100).rounded())
        let installedOnDisk: Bool
        if let prefixPath {
            installedOnDisk = steamLibrary.isInstalled(appID: game.appID, prefixPath: prefixPath)
        } else {
            installedOnDisk = false
        }
        let installed = steamLibrary.installedApps.contains(game.appID) || installedOnDisk

        return VStack(alignment: .leading, spacing: 10) {
            SteamGameArtworkView(game: game)
                .frame(height: 188)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text(game.name.isEmpty ? tr("Untitled Steam app") : game.name)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 38, alignment: .topLeading)
            let downloadBytes = game.downloadSize(for: "windows")
            if downloadBytes > 0 {
                Text(tr("Approx. download size: %@", ByteCountFormatter.string(fromByteCount: Int64(clamping: downloadBytes), countStyle: .file)))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            } else {
                Text(tr("App ID: %u", game.appID))
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if installed {
                Label(tr("Installed"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if steamLibrary.installingApps.contains(game.appID) {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress?.fraction ?? 0)
                        .tint(.white)
                    Text(tr("Downloading %d%%", percent))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                }
                .padding(.vertical, 4)
            } else {
                if let error = steamLibrary.downloadErrors[game.appID] {
                    Text(tr(error))
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
                if game.installableOnWindows {
                    Button { install(game) } label: {
                        Label(tr("Install"), systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.12, green: 0.35, blue: 0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                } else {
                    Text(tr("Not available for Windows"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelColor)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private func resolvePrefixPath() {
        coordinator.containerHost.mountEnvironment { mountedPath in
            guard let mountedPath else { return }
            let root = URL(fileURLWithPath: mountedPath, isDirectory: true)
            Task { @MainActor in prefixPath = root }
        }
    }

    private func install(_ game: SteamAppInfo) {
        coordinator.containerHost.mountEnvironment { mountedPath in
            guard let mountedPath else {
                coordinator.setWindowsStatus("Container initialization failed")
                return
            }
            let root = URL(fileURLWithPath: mountedPath, isDirectory: true)
            Task { @MainActor in
                prefixPath = root
                await steamLibrary.install(appID: game.appID, prefixPath: root)
            }
        }
    }
}
