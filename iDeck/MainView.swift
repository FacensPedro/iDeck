import SwiftUI
import UniformTypeIdentifiers

enum IDeckWorkspace {
    case pc
    case liveContainer
}

struct MainView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedWorkspace: IDeckWorkspace?

    var body: some View {
        Group {
            if let selectedWorkspace {
                WindowsWorkspaceView(coordinator: coordinator, onBack: {
                    self.selectedWorkspace = nil
                }, mode: selectedWorkspace)
            } else {
                homeView
            }
        }
        .onAppear { coordinator.refreshJITStatus() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { coordinator.refreshJITStatus() }
        }
        .fullScreenCover(isPresented: Binding<Bool>(
            get: {
                coordinator.windowsStatus == "Steam Running" ||
                coordinator.windowsStatus == "Running"
            },
            set: { _ in coordinator.setWindowsStatus("Windows Ready") }
        )) {
            GameSessionView(coordinator: coordinator)
        }
    }

    private var homeView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    Image("IDeckLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                    Text("iDeck")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    Text(tr("Choose a mode"))
                        .foregroundColor(.gray)
                    Button {
                        selectedWorkspace = .pc
                        if !coordinator.isContainerReady {
                            coordinator.forceJITAndStartWindows()
                        }
                    } label: {
                        modeTile(title: tr("Madeira"), subtitle: tr("Steam games and Windows apps"), symbol: "gamecontroller.fill")
                    }
                    .buttonStyle(.plain)
                    Button {
                        selectedWorkspace = .liveContainer
                    } label: {
                        modeTile(title: tr("LiveContainer"), subtitle: tr("Install and run IPA apps"), symbol: "square.stack.3d.up.fill")
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 520)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func modeTile(title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundColor(.white)
            Text(title)
                .font(.title3.bold())
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                image.resizable().scaledToFit()
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

struct SteamGameBannerView: View {
    let game: SteamAppInfo
    @State private var imageIndex = 0

    private var candidates: [URL] {
        var urls: [URL] = []
        for asset in [game.libraryHero, game.headerImage] {
            guard let asset, !asset.isEmpty, asset.utf8.count <= 256,
                  !asset.hasPrefix("/"), !asset.contains(".."),
                  asset.unicodeScalars.allSatisfy({
                      $0.isASCII && (CharacterSet.alphanumerics.contains($0) ||
                      "._-/".unicodeScalars.contains($0))
                  }) else { continue }
            if let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.appID)/\(asset)") {
                urls.append(url)
            }
        }
        if let fallback = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)/header.jpg") {
            urls.append(fallback)
        }
        return urls
    }

    var body: some View {
        AsyncImage(url: imageIndex < candidates.count ? candidates[imageIndex] : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else if phase.error != nil {
                Color.white.opacity(0.06)
                    .onAppear { if imageIndex + 1 < candidates.count { imageIndex += 1 } }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView().tint(.gray)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: game.appID) { imageIndex = 0 }
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
    let onBack: (() -> Void)?
    let mode: IDeckWorkspace

    @State private var isSettingsPresented = false
    @State private var isSteamSignInPresented = false
    @State private var searchText = ""
    @State private var prefixPath: URL?
    @StateObject private var steamLibrary = SteamOwnedGamesModel()
    @StateObject private var appManager = AppManager()
    @StateObject private var windowsLibrary = WindowsLibraryStore()
    @State private var isExecutablePickerPresented = false
    @State private var isExecutableMenuPresented = false
    @State private var isIPAPickerPresented = false
    @State private var selectedGuestApp: SelectedLibraryURL?
    @State private var selectedExecutable: SelectedLibraryURL?
    @State private var selectedSteamGame: SelectedSteamGame?
    @State private var installMessage: String?
    @State private var isShowingInstallResult = false
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let panelColor = Color(red: 0.105, green: 0.105, blue: 0.115)
    private let secondaryColor = Color(red: 0.16, green: 0.16, blue: 0.17)

    private var filteredSteamGames: [SteamAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return steamLibrary.games }
        return steamLibrary.games.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.appID).contains(query)
        }
    }

    private var installedSteamGames: [SteamAppInfo] {
        steamLibrary.games.filter { game in
            steamLibrary.installingApps.contains(game.appID) ||
            steamLibrary.installedApps.contains(game.appID) ||
            (prefixPath.map { steamLibrary.isInstalled(appID: game.appID, prefixPath: $0) } ?? false)
        }
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isCompact ? 140 : 184, maximum: isCompact ? 184 : 226), spacing: isCompact ? 10 : 16)]
    }

    private var artworkWidth: CGFloat { isCompact ? 112 : 148 }
    private var artworkHeight: CGFloat { isCompact ? 168 : 222 }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if mode == .pc {
                        Group {
                            if !isCompact && !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .center, spacing: 14) {
                                libraryHeading
                                Spacer(minLength: 8)
                                steamConnectButton
                            }
                            } else {
                            VStack(alignment: .leading, spacing: 14) {
                                libraryHeading
                                steamConnectButton
                            }
                            }
                        }

                        installedProgramsContent

                        if coordinator.isSteamConnected {
                            HStack {
                                Spacer()
                                Button {
                                    Task { await steamLibrary.refresh(force: true) }
                                } label: {
                                    Label(tr("Refresh library"), systemImage: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                            }
                            libraryContent
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

                        } else {
                            liveContainerContent
                        }
                    }
                    .frame(maxWidth: 1000)
                    .padding(.horizontal, isCompact ? 14 : 28)
                    .padding(.top, isCompact ? 16 : 28)
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
        .sheet(item: $selectedGuestApp) { selection in
            GuestProgramDetailsView(appURL: selection.url, appManager: appManager, coordinator: coordinator)
        }
        .sheet(item: $selectedExecutable) { selection in
            WindowsExecutableDetailsView(executableURL: selection.url, prefixPath: prefixPath, library: windowsLibrary, coordinator: coordinator)
        }
        .sheet(item: $selectedSteamGame) { selection in
            SteamProgramDetailsView(game: selection.game, prefixPath: prefixPath, library: windowsLibrary, steamLibrary: steamLibrary, coordinator: coordinator)
        }
        .fileImporter(
            isPresented: $isExecutablePickerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first, let prefixPath else { return }
            do {
                _ = try windowsLibrary.importExecutable(from: url, prefixPath: prefixPath)
            } catch {
                installMessage = error.localizedDescription
                isShowingInstallResult = true
            }
        }
        .fileImporter(
            isPresented: $isIPAPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                appManager.installIPA(from: url) { result in
                    switch result {
                    case .success(let appURL):
                        selectedGuestApp = SelectedLibraryURL(url: appURL)
                    case .failure(let error):
                        installMessage = error.localizedDescription
                        isShowingInstallResult = true
                    }
                }
            case .failure(let error):
                installMessage = error.localizedDescription
                isShowingInstallResult = true
            }
        }
        .alert(tr("Library"), isPresented: $isShowingInstallResult) {
            Button(tr("OK"), role: .cancel) { }
        } message: {
            Text(installMessage ?? tr("Operation completed."))
        }
        .task(id: coordinator.isSteamConnected) {
            if coordinator.isSteamConnected {
                await steamLibrary.refresh()
            } else {
                steamLibrary.disconnect()
            }
        }
        .onAppear {
            resolvePrefixPath()
            appManager.refreshInstalledApps()
        }
        .preferredColorScheme(.dark)
    }

    private var liveContainerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("LiveContainer Apps"))
                .font(.title2.bold())
                .foregroundColor(.white)
            Button {
                isIPAPickerPresented = true
            } label: {
                Label(tr("Install IPA"), systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)

            if appManager.installedApps.isEmpty {
                Text(tr("No apps installed. Tap + to install an .ipa"))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(appManager.installedApps, id: \.path) { appURL in
                        VStack(spacing: 10) {
                            Button {
                                selectedGuestApp = SelectedLibraryURL(url: appURL)
                            } label: {
                                VStack(spacing: 9) {
                                    AppBundleArtworkView(appURL: appURL, appManager: appManager)
                                        .frame(width: artworkWidth, height: artworkHeight)
                                    cardTitle(appManager.displayName(for: appURL))
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                launchGuest(appURL)
                            } label: {
                                Label(tr("Launch"), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(panelColor)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                }
            }
        }
    }

    private func launchGuest(_ appURL: URL) {
        coordinator.refreshJITStatus()
        guard coordinator.isJITEnabled else {
            installMessage = tr("Activate JIT with StikDebug, then confirm it in Settings.")
            isShowingInstallResult = true
            return
        }
        coordinator.forceJITAndStartLiveContainer()
        coordinator.launchGuestApp(at: appURL)
        if coordinator.liveContainerStatus.hasPrefix("Guest launch failed") {
            installMessage = coordinator.liveContainerStatus
            isShowingInstallResult = true
        }
    }

    private var libraryHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(tr("Game Library"))
                .font(.system(size: isCompact ? 25 : 29, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(tr("Install games from your Steam library"))
                .font(.subheadline)
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steamConnectButton: some View {
        HStack(spacing: 10) {
            Button {
                isSteamSignInPresented = true
            } label: {
                Label(tr(coordinator.isSteamConnected ? "Steam connected" : "Connect Steam"),
                      systemImage: coordinator.isSteamConnected ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .background(Color(red: 0.12, green: 0.35, blue: 0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button {
                isExecutableMenuPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(secondaryColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(tr("Install .exe"))
            .confirmationDialog(tr("Add Windows app"), isPresented: $isExecutableMenuPresented) {
                Button(tr("Install .exe")) { isExecutablePickerPresented = true }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if let onBack = onBack {
                Button(action: onBack) {
                    Label(tr("Home"), systemImage: "house.fill")
                        .foregroundColor(.white)
                }
            }
            Spacer()
            Text(mode == .pc ? tr("Madeira") : tr("LiveContainer"))
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
        .padding(.horizontal, isCompact ? 14 : 24)
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

        return VStack(alignment: .center, spacing: 10) {
            Button {
                selectedSteamGame = SelectedSteamGame(game: game)
            } label: {
                VStack(alignment: .center, spacing: 9) {
                    SteamGameArtworkView(game: game)
                        .frame(width: artworkWidth, height: artworkHeight)
                    cardTitle(game.name.isEmpty ? tr("Untitled Steam app") : game.name)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let downloadBytes = game.downloadSize(for: "windows")
            if downloadBytes > 0 {
                Text("(\(ByteCountFormatter.string(fromByteCount: Int64(clamping: downloadBytes), countStyle: .file)))")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            } else {
                Text(tr("Size unavailable"))
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if installed {
                Button { launchSteamGame(game) } label: {
                    Label(tr("Launch"), systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.12, green: 0.35, blue: 0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            } else if steamLibrary.installingApps.contains(game.appID) {
                downloadControls(for: game)
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

    private func downloadControls(for game: SteamAppInfo) -> some View {
        let progress = steamLibrary.downloadProgress[game.appID]
        let stopping = steamLibrary.cancellingApps.contains(game.appID)
        return VStack(spacing: 8) {
            ProgressView(value: progress?.fraction ?? 0)
                .tint(.white)
            Text(progress?.phase == .preparing
                 ? tr("Preparing download...")
                 : progress?.phase == .finishing
                   ? tr("Finishing installation...")
                   : tr("Downloading %d%%", Int(((progress?.fraction ?? 0) * 100).rounded())))
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
            if steamLibrary.canCancelInstall(appID: game.appID) {
                Button(role: .destructive) {
                    steamLibrary.cancelInstall(appID: game.appID)
                } label: {
                    Label(stopping ? tr("Stopping...") : tr("Stop download"),
                          systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(stopping)
            }
        }
        .padding(.vertical, 4)
    }

    private func resolvePrefixPath() {
        coordinator.containerHost.mountEnvironment { mountedPath in
            guard let mountedPath else { return }
            let root = URL(fileURLWithPath: mountedPath, isDirectory: true)
            Task { @MainActor in
                prefixPath = root
                windowsLibrary.refresh(prefixPath: root)
                appManager.refreshInstalledApps()
            }
        }
    }

    private var installedProgramsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Installed games"))
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text(tr("%d installed", windowsLibrary.executableURLs.count + installedSteamGames.count))
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if windowsLibrary.executableURLs.isEmpty && installedSteamGames.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title2)
                        .foregroundColor(.gray)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Your installed games will appear here"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
}
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panelColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(installedSteamGames, id: \.appID) { game in
                        VStack(spacing: 8) {
                        Button {
                            selectedSteamGame = SelectedSteamGame(game: game)
                        } label: {
                            VStack(alignment: .center, spacing: 9) {
                                SteamGameArtworkView(game: game)
                                    .frame(width: artworkWidth, height: artworkHeight)
                                cardTitle(game.name.isEmpty ? tr("Untitled Steam app") : game.name)
                                Text(tr("Steam · Windows game"))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(panelColor)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                        if steamLibrary.installingApps.contains(game.appID) {
                            downloadControls(for: game)
                        } else {
                            Button { launchSteamGame(game) } label: {
                                Label(tr("Launch"), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        }
                    }

                    ForEach(windowsLibrary.executableURLs, id: \.path) { executableURL in
                        VStack(spacing: 8) {
                        Button {
                            selectedExecutable = SelectedLibraryURL(url: executableURL)
                        } label: {
                            VStack(alignment: .center, spacing: 9) {
                                WindowsExecutableArtworkView(executableURL: executableURL, library: windowsLibrary, fallbackColor: panelColor)
                                    .frame(width: artworkWidth, height: artworkHeight)
                                cardTitle(executableURL.deletingPathExtension().lastPathComponent)
                                Text(tr("Windows app"))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(panelColor)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                        Button {
                            coordinator.refreshJITStatus()
                            guard coordinator.isJITEnabled else {
                                installMessage = tr("Activate JIT with StikDebug, then confirm it in Settings.")
                                isShowingInstallResult = true
                                return
                            }
                            let profile = windowsLibrary.profile(
                                for: windowsLibrary.profileID(for: executableURL),
                                title: executableURL.deletingPathExtension().lastPathComponent)
                            coordinator.launchWindowsExecutable(at: executableURL, profile: profile)
                        } label: {
                            Label(tr("Launch"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private func launchSteamGame(_ game: SteamAppInfo) {
        coordinator.refreshJITStatus()
        guard coordinator.isJITEnabled else {
            installMessage = tr("Activate JIT with StikDebug, then confirm it in Settings.")
            isShowingInstallResult = true
            return
        }
        guard let prefixPath else {
            installMessage = tr("Windows environment is not ready.")
            isShowingInstallResult = true
            return
        }
        let profile = windowsLibrary.profile(for: "steam:\(game.appID)", title: game.name)
        coordinator.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath)
        if coordinator.windowsStatus.hasPrefix("Cannot launch") || coordinator.windowsStatus.hasPrefix("Madeira runtime missing") {
            installMessage = coordinator.windowsStatus
            isShowingInstallResult = true
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
                steamLibrary.startInstall(appID: game.appID, prefixPath: root)
            }
        }
    }
}


private struct WindowsExecutableArtworkView: View {
    let executableURL: URL
    @ObservedObject var library: WindowsLibraryStore
    let fallbackColor: Color

    var body: some View {
        let profile = library.profile(for: library.profileID(for: executableURL), title: executableURL.deletingPathExtension().lastPathComponent)
        Group {
            if let url = library.artworkURL(for: profile), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.18, blue: 0.24), fallbackColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "app.dashed")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityLabel(profile.title)
    }
}

private struct AppBundleArtworkView: View {
    let appURL: URL
    @ObservedObject var appManager: AppManager

    var body: some View {
        Group {
            if let icon = appManager.iconImage(for: appURL) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.05))
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "app.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.gray)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(appManager.displayName(for: appURL))
    }
}

private struct GuestProgramDetailsView: View {
    let appURL: URL
    @ObservedObject var appManager: AppManager
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isArtworkPickerPresented = false

    private var displayName: String { appManager.displayName(for: appURL) }
    @State private var appSize: Int64 = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    AppBundleArtworkView(appURL: appURL, appManager: appManager)
                        .frame(width: 160, height: 160)
                    Button {
                        isArtworkPickerPresented = true
                    } label: {
                        Label(tr("Change cover"), systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    Text(displayName)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text(appManager.bundleIdentifier(for: appURL) ?? appURL.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textSelection(.enabled)
                    Text(tr("App size: %@", ByteCountFormatter.string(
                        fromByteCount: appSize, countStyle: .file)))
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    Button {
                        coordinator.refreshJITStatus()
                        guard coordinator.isJITEnabled else {
                            errorMessage = tr("Activate JIT with StikDebug, then confirm it in Settings.")
                            showError = true
                            return
                        }
                        coordinator.forceJITAndStartLiveContainer()
                        coordinator.launchGuestApp(at: appURL)
                        if coordinator.liveContainerStatus.hasPrefix("Guest launch failed") {
                            errorMessage = coordinator.liveContainerStatus
                            showError = true
                            return
                        }
                        dismiss()
                    } label: {
                        Label(tr("Open app"), systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        do {
                            try appManager.uninstallApp(at: appURL)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    } label: {
                        Label(tr("Uninstall"), systemImage: "trash")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("App details"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: appURL) {
                let url = appURL
                appSize = await Task.detached(priority: .utility) {
                    AppManager.sizeOfInstalledApp(at: url)
                }.value
            }
            .fileImporter(isPresented: $isArtworkPickerPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try appManager.setArtwork(from: url, for: appURL)
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
            .alert(tr("Uninstall failed"), isPresented: $showError) {
                Button(tr("OK"), role: .cancel) { }
            } message: {
                Text(errorMessage ?? tr("Unknown error"))
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct WindowsExecutableDetailsView: View {
    let executableURL: URL
    let prefixPath: URL?
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var profile: WindowsGameProfile
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isArtworkPickerPresented = false

    init(executableURL: URL, prefixPath: URL?, library: WindowsLibraryStore, coordinator: SystemCoordinator) {
        self.executableURL = executableURL
        self.prefixPath = prefixPath
        self.library = library
        self.coordinator = coordinator
        let profileID = library.profileID(for: executableURL)
        _profile = State(initialValue: library.profile(for: profileID, title: executableURL.deletingPathExtension().lastPathComponent))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 10) {
                        WindowsExecutableArtworkView(executableURL: executableURL, library: library, fallbackColor: Color(red: 0.12, green: 0.15, blue: 0.2))
                            .frame(width: 190, height: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                        Button {
                            isArtworkPickerPresented = true
                        } label: {
                            Label(tr("Change cover"), systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                        Text(executableURL.deletingPathExtension().lastPathComponent)
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text(executableURL.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    WindowsGameProfileForm(profile: $profile,
                                           globalMetalFXEnabled: $coordinator.isMetalFXEnabled)
                    Button {
                        guard coordinator.isJITEnabled else {
                            errorMessage = tr("Activate JIT with StikDebug, then confirm it in Settings.")
                            showError = true
                            return
                        }
                        guard let prefixPath, coordinator.windowsEnvironment.hasRuntime(in: prefixPath.path) else {
                            errorMessage = tr("The native Madeira runtime is not linked into this build yet.")
                            showError = true
                            return
                        }
                        library.save(profile)
                        coordinator.launchWindowsExecutable(at: executableURL, profile: profile)
                        dismiss()
                    } label: {
                        Label(tr("Launch"), systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        guard let prefixPath else {
                            errorMessage = tr("Windows environment is not ready.")
                            showError = true
                            return
                        }
                        do {
                            try library.uninstallExecutable(at: executableURL, prefixPath: prefixPath)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    } label: {
                        Label(tr("Uninstall"), systemImage: "trash")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Game details"))
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $isArtworkPickerPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        profile.artworkFilename = try library.setArtwork(from: url, for: profile.id)
                        library.save(profile)
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save")) {
                        library.save(profile)
                        dismiss()
                    }
                }
            }
            .alert(tr("Operation failed"), isPresented: $showError) {
                Button(tr("OK"), role: .cancel) { }
            } message: {
                Text(errorMessage ?? tr("Unknown error"))
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SteamProgramDetailsView: View {
    let game: SteamAppInfo
    let prefixPath: URL?
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var steamLibrary: SteamOwnedGamesModel
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var profile: WindowsGameProfile
    @State private var errorMessage: String?
    @State private var showError = false

    init(game: SteamAppInfo, prefixPath: URL?, library: WindowsLibraryStore,
         steamLibrary: SteamOwnedGamesModel, coordinator: SystemCoordinator) {
        self.game = game
        self.prefixPath = prefixPath
        self.library = library
        self.steamLibrary = steamLibrary
        self.coordinator = coordinator
        var initial = library.profile(for: "steam:\(game.appID)", title: game.name)
        if coordinator.isMetalFXEnabled { initial.metalFXEnabled = true }
        _profile = State(initialValue: initial)
    }

    private var installed: Bool {
        guard let prefixPath else { return false }
        return steamLibrary.isInstalled(appID: game.appID, prefixPath: prefixPath)
    }

    private var installing: Bool {
        steamLibrary.installingApps.contains(game.appID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    ZStack {
                        SteamGameBannerView(game: game)
                            .frame(height: 250)
                        SteamGameArtworkView(game: game)
                            .frame(width: 160, height: 220)
                            .background(Color.black.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .shadow(color: .black.opacity(0.4), radius: 12)
                    }
                    .frame(maxWidth: .infinity)
                    Text(game.name)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text(tr("Steam app ID: %u", game.appID))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Label(installed ? tr("Installed") : tr("Not installed"),
                          systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundColor(installed ? .green : .gray)
                    WindowsGameProfileForm(profile: $profile,
                                           globalMetalFXEnabled: $coordinator.isMetalFXEnabled)
                    if let saveURL = URL(string: "https://store.steampowered.com/account/remotestorageapp/?appid=\(game.appID)") {
                        Link(destination: saveURL) {
                            Label(tr("View Steam Cloud saves"), systemImage: "icloud")
                                .frame(maxWidth: .infinity)
                                .padding(12)
                        }
                        .buttonStyle(.bordered)
                        Text(tr("Steam Cloud files open on Steam; in-app synchronization is not available yet."))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    if installing {
                        downloadStatus
                    } else if installed {
                        Button {
                            coordinator.refreshJITStatus()
                            guard coordinator.isJITEnabled else {
                                presentError(tr("JIT is not available. Activate it for iDeck in StikDebug."))
                                return
                            }
                            guard let prefixPath else {
                                presentError(tr("Windows environment is not ready."))
                                return
                            }
                            profile.metalFXEnabled = coordinator.isMetalFXEnabled || profile.metalFXEnabled
                            library.save(profile)
                            coordinator.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath)
                            if coordinator.windowsStatus.hasPrefix("Cannot launch") ||
                               coordinator.windowsStatus.hasPrefix("Madeira runtime missing") {
                                presentError(coordinator.windowsStatus)
                            } else {
                                dismiss()
                            }
                        } label: {
                            Label(tr("Launch"), systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .destructive) {
                            guard let prefixPath else { return }
                            if steamLibrary.uninstall(appID: game.appID, prefixPath: prefixPath) {
                                library.removeProfile(for: "steam:\(game.appID)")
                                dismiss()
                            } else {
                                presentError(tr("Steam could not safely remove this game's files. Refresh the library and try again."))
                            }
                        } label: {
                            Label(tr("Uninstall"), systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            guard let prefixPath else {
                                presentError(tr("Windows environment is not ready."))
                                return
                            }
                            steamLibrary.startInstall(appID: game.appID, prefixPath: prefixPath)
                        } label: {
                            Label(tr("Install"), systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(prefixPath == nil || !game.installableOnWindows)
                    }

                    if installed {
                        dlcList
                    }
                    if let error = steamLibrary.downloadErrors[game.appID] {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Game details"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: game.appID) {
                await steamLibrary.loadDLC(appID: game.appID)
                if let prefixPath {
                    steamLibrary.refreshInstalledDLC(appID: game.appID, prefixPath: prefixPath)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save")) {
                        profile.metalFXEnabled = coordinator.isMetalFXEnabled || profile.metalFXEnabled
                        library.save(profile)
                        dismiss()
                    }
                }
            }
            .alert(tr("Operation failed"), isPresented: $showError) {
                Button(tr("OK"), role: .cancel) { }
            } message: {
                Text(errorMessage ?? tr("Unknown error"))
            }
        }
        .preferredColorScheme(.dark)
    }

    private var downloadStatus: some View {
        let progress = steamLibrary.downloadProgress[game.appID]
        let stopping = steamLibrary.cancellingApps.contains(game.appID)
        return VStack(spacing: 10) {
            ProgressView(value: progress?.fraction ?? 0)
            Text(progress?.phase == .preparing ? tr("Preparing download...") :
                 progress?.phase == .finishing ? tr("Finishing installation...") :
                 tr("Downloading %d%%", Int(((progress?.fraction ?? 0) * 100).rounded())))
                .font(.caption)
                .foregroundColor(.white)
            if steamLibrary.canCancelInstall(appID: game.appID) {
                Button(role: .destructive) {
                    steamLibrary.cancelInstall(appID: game.appID)
                } label: {
                    Label(stopping ? tr("Stopping...") : tr("Stop download"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(stopping)
                .buttonStyle(.bordered)
            }
        }
    }

    private var dlcList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("DLC for this game"))
                .font(.headline)
                .foregroundColor(.white)
            let ids = steamLibrary.availableDLC[game.appID] ?? []
            if ids.isEmpty {
                Text(tr("No DLC found for this game"))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 12) {
                    SteamGameArtworkView(game: steamLibrary.dlcMetadata[id] ?? SteamAppInfo(appID: id))
                        .frame(width: 58, height: 78)
                    Text(steamLibrary.dlcMetadata[id]?.name ?? "DLC \(id)")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if steamLibrary.installedDLC[game.appID]?.contains(id) == true {
                        Button(role: .destructive) {
                            guard let prefixPath,
                                  steamLibrary.uninstallDLC(appID: game.appID,
                                                            dlcAppID: id, prefixPath: prefixPath) else {
                                presentError(tr("Could not uninstall DLC safely."))
                                return
                            }
                        } label: {
                            Label(tr("Uninstall"), systemImage: "trash")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            guard let prefixPath else {
                                presentError(tr("Windows environment is not ready."))
                                return
                            }
                            Task {
                                await steamLibrary.installDLC(appID: game.appID,
                                                               dlcAppID: id, prefixPath: prefixPath)
                            }
                        } label: {
                            Text(tr("Install"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

private struct WindowsGameProfileForm: View {
    @Binding var profile: WindowsGameProfile
    @Binding var globalMetalFXEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Game configuration"))
                .font(.headline)
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Launch arguments"))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                TextField(tr("Example: -windowed"), text: $profile.arguments)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            profilePicker(title: tr("Resolution"), selection: $profile.resolution, choices: ["Device native", "960x540", "1280x720", "1600x900", "1920x1080"])
            profilePicker(title: tr("Graphics API"), selection: $profile.graphicsAPI, choices: ["Automatic", "Direct3D 9", "Direct3D 10", "Direct3D 11", "Direct3D 12"])
            profilePicker(title: tr("Frame rate limit"), selection: $profile.fpsLimit, choices: ["30", "40", "60", "Uncapped"])
            Toggle(tr("MetalFX upscaling"), isOn: $globalMetalFXEnabled)
                .tint(.blue)
            Toggle(tr("Enable AVX/AVX2 translation"), isOn: $profile.avxEnabled)
                .tint(.blue)
        }
        .padding(16)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func profilePicker(title: String, selection: Binding<String>, choices: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.gray)
            Picker(title, selection: selection) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
