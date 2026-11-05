import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.scenePhase) private var scenePhase
    // Lazily retained: a download remains owned when navigating home, but
    // the Steam session is not constructed during process cold-start.
    @State private var steamLibrary: SteamOwnedGamesModel?

    var body: some View {
        Group {
            if let steamLibrary {
                WindowsWorkspaceView(coordinator: coordinator, steamLibrary: steamLibrary)
            } else {
                Color.black.ignoresSafeArea()
                    .task {
                        await Task.yield()
                        coordinator.configureNativeHostIfNeeded()
                        coordinator.loadSteamAccountIfNeeded()
                        steamLibrary = SteamOwnedGamesModel.shared
                        coordinator.openMadeiraWorkspace()
                    }
            }
        }
        .onAppear {
            // First paint must be independent of the native Madeira runtime,
            // the external debugger and the stored Steam session.
            NSLog("[iDeck startup] Madeira library is the root view")
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase == .active && steamLibrary != nil {
                coordinator.refreshJITStatus()
            }
        }
        .task(id: steamLibrary != nil && scenePhase == .active) {
            guard steamLibrary != nil && scenePhase == .active else { return }
            while !Task.isCancelled {
                coordinator.refreshJITStatus()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
        .task(id: steamLibrary != nil && coordinator.isSteamConnected) {
            guard let steamLibrary else { return }
            if coordinator.isSteamConnected {
                await steamLibrary.refresh()
            } else {
                steamLibrary.disconnect()
            }
        }
        .alert(tr("Install Microsoft Visual C++?"),
               isPresented: $coordinator.needsVisualCRuntimeConsent) {
            Button(tr("Install and play")) {
                coordinator.approveVisualCRuntimeInstallation()
            }
            Button(tr("Play without installing"), role: .cancel) {
                coordinator.skipVisualCRuntimeInstallation()
            }
        } message: {
            Text(tr("iDeck can download and extract the official Microsoft x64 Visual C++ Redistributable directly on this iPad before launching a Windows game. No Windows installer needs to run. The 14 x64 DLLs are verified before they are made available to Wine."))
        }
        .fullScreenCover(isPresented: Binding<Bool>(
            get: {
                coordinator.windowsStatus == "Closing Windows session..." ||
                coordinator.windowsStatus == "Steam Running" ||
                coordinator.windowsStatus == "Running" ||
                coordinator.windowsStatus == "Wine started; waiting for game..." ||
                coordinator.windowsStatus == "Launching Steam game..." ||
                coordinator.windowsStatus == "Launching Steam client..." ||
                coordinator.windowsStatus == "Launching Windows app..." ||
                coordinator.windowsStatus == "Installing Steam prerequisites..." ||
                coordinator.windowsStatus == "Preparing JIT..." ||
                coordinator.windowsStatus == VisualCRuntimeBootstrap.installStatus ||
                coordinator.windowsStatus == SystemCoordinator.steamComponentsInstallStatus ||
                coordinator.windowsStatus.hasPrefix("Visual C++") ||
                coordinator.windowsStatus.hasPrefix("Execution Error:")
            },
            set: { presented in
                if !presented && coordinator.windowsStatus != "Windows Ready" &&
                   coordinator.windowsStatus != "Closing Windows session..." {
                    coordinator.requestCloseWindowsSession()
                }
            }
        )) {
            GameSessionView(coordinator: coordinator)
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

/// A GOG or Epic game's banner, drawn exactly like SteamGameBannerView:
/// the whole image fitted in a 220-point rounded panel.
private struct GameDetailsBannerFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct StoreBannerView: View {
    let urls: [URL]
    @State private var imageIndex = 0

    var body: some View {
        AsyncImage(url: imageIndex < urls.count ? urls[imageIndex] : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else if phase.error != nil || urls.isEmpty {
                Color.white.opacity(0.06)
                    .onAppear { if imageIndex + 1 < urls.count { imageIndex += 1 } }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView().tint(.gray)
                }
            }
        }
        .modifier(GameDetailsBannerFrame())
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
        .modifier(GameDetailsBannerFrame())
        .task(id: game.appID) { imageIndex = 0 }
    }
}

struct WindowsWorkspaceView: View {
    @ObservedObject var coordinator: SystemCoordinator
    let onBack: (() -> Void)?
    let mode: IDeckWorkspace
    @ObservedObject var steamLibrary: SteamOwnedGamesModel

    @State private var isSettingsPresented = false
    @State private var searchText = ""
    /// The selected tile of the console-style shelf (a store or a game).
    @State var shelf: ShelfItem = .store(.steam)
    @State private var prefixPath: URL?
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
    @State private var pendingSteamCompatibilityLaunch: (game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL)?
    @State private var steamCompatibilityMessage = ""
    @State private var showingSteamCompatibilityWarning = false
    @ObservedObject private var gogLibrary = GOGLibraryModel.shared
    @State private var isGOGSignInPresented = false
    @AppStorage("library.gogOwnedCollapsed") private var gogOwnedCollapsed = false
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @State private var isEpicSignInPresented = false
    @State private var selectedEpicGame: SelectedEpicGame?
    @State private var selectedGOGGame: GOGGame?
    @AppStorage("library.epicOwnedCollapsed") private var epicOwnedCollapsed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Same palette as iRelay (panel #0b0b0d, card #111114, line #1f1f24).
    private let panelColor = Color(red: 0x0b/255, green: 0x0b/255, blue: 0x0d/255)
    private let secondaryColor = Color(red: 0x11/255, green: 0x11/255, blue: 0x14/255)
    private let lineColor = Color(red: 0x1f/255, green: 0x1f/255, blue: 0x24/255)
    private let accentColor = Color(red: 0x3b/255, green: 0x82/255, blue: 0xf6/255)
    private let textColor = Color(red: 0xf4/255, green: 0xf4/255, blue: 0xf5/255)
    private let faintColor = Color(red: 0x71/255, green: 0x71/255, blue: 0x7a/255)

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
            steamLibrary.installedApps.contains(game.appID)
        }
    }

    private var filteredGOGGames: [GOGGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return gogLibrary.games }
        return gogLibrary.games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var filteredEpicGames: [EpicOwnedGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return epicLibrary.owned }
        return epicLibrary.owned.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var installedEpicGames: [EpicInstalledGame] {
        epicLibrary.installed.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var installedGOGGames: [GOGInstalledGame] {
        gogLibrary.installed.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// GOG and Epic games being installed: listed under Installed games with
    /// their progress, as Steam games are while they download.
    private var installingGOGGames: [GOGGame] {
        gogLibrary.games.filter { gogLibrary.downloadProgress[$0.id] != nil && gogLibrary.installed[$0.id] == nil }
    }

    private var installingEpicGames: [EpicOwnedGame] {
        epicLibrary.owned.filter { epicLibrary.downloads[$0.appName] != nil && epicLibrary.installed[$0.appName] == nil }
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// Height of every card's action row (Launch, Install, progress), so a
    /// game that is installing keeps exactly the size of an installed one.
    private let cardActionHeight: CGFloat = 40

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isCompact ? 140 : 184, maximum: isCompact ? 184 : 226), spacing: isCompact ? 10 : 16)]
    }

    private var artworkWidth: CGFloat { isCompact ? 112 : 148 }
    private var artworkHeight: CGFloat { isCompact ? 168 : 222 }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundColor(textColor)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The shared look of a card's primary action, at `cardActionHeight`.
    private func cardActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: cardActionHeight)
            .background(accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Download progress in the same footprint as the Launch button: a bar
    /// with the percentage, and a stop button. Details are in the game sheet.
    private func progressAction(fraction: Double, label: String, onPause: (() -> Void)? = nil,
                                onStop: (() -> Void)?, stopping: Bool = false) -> some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1))
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accentColor)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            if let onPause {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.caption)
                        .frame(width: cardActionHeight, height: cardActionHeight)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(stopping)
                .accessibilityLabel(tr("Pause download"))
            }
            if let onStop {
                Button(role: .destructive, action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .frame(width: cardActionHeight, height: cardActionHeight)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(stopping)
                .accessibilityLabel(stopping ? tr("Stopping...") : tr("Stop download"))
            }
        }
        .frame(height: cardActionHeight)
    }

    /// A collapsible "owned games" header (store, count, chevron).
    private func ownedHeader(_ title: String, collapsed: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(faintColor)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.gray)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed.wrappedValue ? tr("Show list") : tr("Hide list"))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if mode == .pc {
                            HStack(alignment: .center, spacing: 14) {
                                libraryHeading
                                Spacer(minLength: 8)
                                steamConnectButton
                            }
                            consoleShelf
                            shelfContent
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
        .sheet(isPresented: $isGOGSignInPresented) {
            GOGSignInView()
        }
        .sheet(isPresented: $isEpicSignInPresented) {
            EpicSignInView()
        }
        .sheet(item: $selectedGOGGame) { game in
            GOGGameDetailsSheet(game: game, prefixPath: prefixPath, gog: gogLibrary, library: windowsLibrary,
                                coordinator: coordinator, launch: { launchGOGGame($0) },
                                install: { downloadGOGInstaller($0) })
        }
        .sheet(item: $selectedEpicGame) { selection in
            EpicGameDetailsSheet(appName: selection.id, epic: epicLibrary, library: windowsLibrary,
                                 coordinator: coordinator) { game in launchEpicGame(game) }
        }
        .onAppear {
            if mode == .pc { epicLibrary.start() }
        }
        .task(id: gogLibrary.isSignedIn) {
            if mode == .pc && gogLibrary.isSignedIn && gogLibrary.games.isEmpty {
                await gogLibrary.refresh()
            }
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
            allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first, let prefixPath else { return }
            do {
                let executable = try windowsLibrary.importExecutable(from: url, prefixPath: prefixPath)
                Task {
                    await windowsLibrary.importEmbeddedIcon(for: executable)
                }
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
        .alert(tr("Steam compatibility warning"), isPresented: $showingSteamCompatibilityWarning) {
            Button(tr("Continue launching")) {
                if let pending = pendingSteamCompatibilityLaunch {
                    coordinator.launchSteamGame(
                        game: pending.game, profile: pending.profile, prefixPath: pending.prefixPath)
                }
                pendingSteamCompatibilityLaunch = nil
            }
            Button(tr("Cancel"), role: .cancel) {
                pendingSteamCompatibilityLaunch = nil
            }
        } message: {
            Text(tr(steamCompatibilityMessage))
        }

        .onAppear {
            resolvePrefixPath()
            appManager.refreshInstalledApps()
        }
        // iRelay copied a game from the PC.
        .onReceive(NotificationCenter.default.publisher(for: IRelayDeviceService.installedNotification)) { _ in
            reloadInstalledGames()
        }
        // A finished Wine session may have installed a game (a GOG installer,
        // a setup program): look for new installs whenever Wine stops.
        .onChange(of: coordinator.windowsStatus) { _, _ in
            guard mode == .pc, let prefixPath, !ideck_wineprocess_running() else { return }
            gogLibrary.refreshInstalled(prefixPath: prefixPath)
            windowsLibrary.refresh(prefixPath: prefixPath)
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
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
            Text(tr("%d installed", windowsLibrary.executableURLs.count + installedSteamGames.count
                    + installedGOGGames.count + installedEpicGames.count))
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }

    private var steamConnectButton: some View {
        HStack(spacing: 10) {
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
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(panelColor)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(lineColor, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .accessibilityLabel(tr("Home"))
            }
            Spacer()
            VStack(spacing: 2) {
                Text(mode == .pc ? tr("Madeira") : tr("LiveContainer"))
                    .font(.headline)
                    .foregroundColor(.white)
                if mode == .pc {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(coordinator.isJITEnabled ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(coordinator.isJITEnabled ? tr("JIT active") : tr("JIT off"))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
            Spacer()
            Button { isSettingsPresented = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(panelColor)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(lineColor, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .accessibilityLabel(tr("Settings"))
        }
        .padding(.horizontal, isCompact ? 14 : 24)
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay(alignment: .bottom) { lineColor.frame(height: 1) }
    }

    /// One game in the combined library, from whichever store owns it.
    private enum MixedLibraryEntry: Identifiable {
        case steam(SteamAppInfo)
        case gog(GOGGame)
        case epic(EpicOwnedGame)

        var id: String {
            switch self {
            case .steam(let game): return "steam:\(game.appID)"
            case .gog(let game): return "gog:\(game.id)"
            case .epic(let game): return "epic:\(game.id)"
            }
        }

        var title: String {
            switch self {
            case .steam(let game): return game.name
            case .gog(let game): return game.title
            case .epic(let game): return game.title
            }
        }
    }

    /// Steam, GOG and Epic games of every connected account, in one list
    /// sorted by name.
    private var mixedLibraryEntries: [MixedLibraryEntry] {
        var entries: [MixedLibraryEntry] = []
        if coordinator.isSteamConnected { entries += filteredSteamGames.map { .steam($0) } }
        if gogLibrary.isSignedIn { entries += filteredGOGGames.map { .gog($0) } }
        if epicLibrary.signedIn { entries += filteredEpicGames.map { .epic($0) } }
        return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var mixedLibraryCount: Int {
        (coordinator.isSteamConnected ? steamLibrary.games.count : 0) +
        (gogLibrary.isSignedIn ? gogLibrary.games.count : 0) +
        (epicLibrary.signedIn ? epicLibrary.owned.count : 0)
    }

    private var mixedLibraryLoading: Bool {
        (coordinator.isSteamConnected && steamLibrary.isLoading) ||
        (gogLibrary.isSignedIn && gogLibrary.isLoading) ||
        (epicLibrary.signedIn && epicLibrary.refreshing)
    }

    /// Short status lines for stores that are loading or failed to load.
    private var mixedLibraryNotices: [(text: String, isError: Bool)] {
        var notices: [(text: String, isError: Bool)] = []
        if coordinator.isSteamConnected {
            if steamLibrary.isLoading { notices.append((tr("Loading Steam library..."), false)) }
            else if let error = steamLibrary.errorMessage { notices.append(("Steam: " + tr(error), true)) }
        }
        if gogLibrary.isSignedIn {
            if gogLibrary.isLoading { notices.append((tr("Loading GOG library..."), false)) }
            else if let error = gogLibrary.errorMessage { notices.append(("GOG: " + tr(error), true)) }
        }
        if epicLibrary.signedIn {
            if epicLibrary.refreshing { notices.append((tr("Loading Epic Games library..."), false)) }
            else if let error = epicLibrary.error { notices.append(("Epic Games: " + error, true)) }
        }
        return notices
    }

    /// Libraries › reload: Steam, GOG and Epic Games lists and what is installed.
    private func refreshAllLibraries() {
        reloadInstalledGames()
        if coordinator.isSteamConnected { Task { await steamLibrary.refresh(force: true) } }
        if gogLibrary.isSignedIn { Task { await gogLibrary.refresh() } }
        if epicLibrary.signedIn { Task { await epicLibrary.refreshLibrary() } }
    }

    private func gameCard(_ game: SteamAppInfo) -> some View {
        let installed = steamLibrary.installedApps.contains(game.appID)

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

            if installed {
                Button { launchSteamGame(game) } label: {
                    cardActionLabel(tr("Launch"), systemImage: "play.fill")
                }
            } else if steamLibrary.pausedInstalls.contains(game.appID) {
                Button { steamLibrary.resumeInstall(appID: game.appID) } label: {
                    cardActionLabel(tr("Resume"), systemImage: "play.circle.fill")
                }
            } else if steamLibrary.installingApps.contains(game.appID) {
                steamProgressAction(for: game)
            } else {
                if let error = steamLibrary.downloadErrors[game.appID] {
                    Text(tr(error))
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
                if game.installableOnWindows {
                    Button { install(game) } label: {
                        cardActionLabel(tr("Install"), systemImage: "arrow.down.circle.fill")
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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var gogContent: some View {
        if gogLibrary.isSignedIn {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ownedHeader(tr("GOG games: %d", gogLibrary.games.count), collapsed: $gogOwnedCollapsed)
                    Button {
                        Task { await gogLibrary.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(gogLibrary.isLoading)
                }
                if !gogOwnedCollapsed {
                    if gogLibrary.isLoading && gogLibrary.games.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(tr("Loading GOG library...")).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let error = gogLibrary.errorMessage, gogLibrary.games.isEmpty {
                        Text(tr(error))
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else if filteredGOGGames.isEmpty {
                        Text(gogLibrary.games.isEmpty ? tr("No GOG games found yet.") : tr("No games match this search"))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filteredGOGGames) { game in gogCard(game) }
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("GOG"))
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(tr("Sign in on GOG's own page to see your GOG games. iDeck keeps only the sign-in token, in this device's Keychain."))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(tr("Connect GOG")) { isGOGSignInPresented = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelColor)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func gogCard(_ game: GOGGame) -> some View {
        let installed = gogLibrary.installed[game.id]
        return VStack(alignment: .center, spacing: 10) {
            Button {
                selectedGOGGame = game
            } label: {
                VStack(alignment: .center, spacing: 9) {
                    GOGArtworkView(urls: game.artworkCandidates, fallbackColor: secondaryColor)
                        .frame(width: artworkWidth, height: artworkHeight)
                    cardTitle(game.title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let error = gogLibrary.downloadErrors[game.id] {
                Text(tr(error))
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            if let installed {
                Button { launchGOGGame(installed) } label: {
                    cardActionLabel(tr("Launch"), systemImage: "play.fill")
                }
            } else if gogLibrary.pausedDownloads.contains(game.id) {
                Button { gogLibrary.resumeDownload(game) } label: {
                    cardActionLabel(tr("Resume"), systemImage: "play.circle.fill")
                }
            } else if let fraction = gogLibrary.downloadProgress[game.id] {
                progressAction(fraction: fraction,
                               label: tr("Installing %d%%", Int((fraction * 100).rounded())),
                               onPause: { gogLibrary.pauseDownload(game) },
                               onStop: { gogLibrary.cancelDownload(game) })
            } else if game.worksOnWindows {
                Button { downloadGOGInstaller(game) } label: {
                    cardActionLabel(tr("Install"), systemImage: "arrow.down.circle.fill")
                }
                .disabled(prefixPath == nil)
            } else {
                Text(tr("Not available for Windows"))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(height: cardActionHeight)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelColor)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var epicContent: some View {
        if epicLibrary.signedIn {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ownedHeader(tr("Epic games: %d", epicLibrary.owned.count), collapsed: $epicOwnedCollapsed)
                    Button {
                        Task { await epicLibrary.refreshLibrary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(epicLibrary.refreshing)
                }
                if !epicOwnedCollapsed {
                    if epicLibrary.refreshing && epicLibrary.owned.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(tr("Loading Epic Games library...")).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let error = epicLibrary.error, epicLibrary.owned.isEmpty {
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else if filteredEpicGames.isEmpty {
                        Text(epicLibrary.owned.isEmpty ? tr("No Epic games found yet.") : tr("No games match this search"))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filteredEpicGames) { game in epicCard(game) }
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Epic Games")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(tr("Sign in on Epic's own page to see your Epic games. iDeck keeps only the sign-in token, in this device's Keychain."))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(tr("Connect Epic")) { isEpicSignInPresented = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelColor)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func epicCard(_ game: EpicOwnedGame) -> some View {
        let installed = epicLibrary.installed[game.appName]
        let download = epicLibrary.downloads[game.appName]
        return VStack(alignment: .center, spacing: 10) {
            Button {
                selectedEpicGame = SelectedEpicGame(id: game.appName)
            } label: {
                VStack(alignment: .center, spacing: 9) {
                    GOGArtworkView(urls: [game.cover].compactMap { $0 }, fallbackColor: secondaryColor)
                        .frame(width: artworkWidth, height: artworkHeight)
                    cardTitle(game.title)
                }
            }
            .buttonStyle(.plain)
            if let download {
                switch download.state {
                case .failed(let message):
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .frame(height: cardActionHeight)
                case .paused:
                    Button { epicLibrary.install(game.appName) } label: {
                        cardActionLabel(tr("Resume"), systemImage: "play.circle.fill")
                    }
                default:
                    progressAction(fraction: download.progress.fraction,
                                   label: tr("Installing %d%%", Int((download.progress.fraction * 100).rounded())),
                                   onPause: { epicLibrary.pause(game.appName) },
                                   onStop: { epicLibrary.cancel(game.appName) })
                }
            } else if let installed {
                Button { launchEpicGame(installed) } label: {
                    cardActionLabel(tr("Launch"), systemImage: "play.fill")
                }
            } else {
                Button { epicLibrary.install(game.appName) } label: {
                    cardActionLabel(tr("Install"), systemImage: "arrow.down.circle.fill")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelColor)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func launchEpicGame(_ game: EpicInstalledGame) {
        guard requireJIT() else { return }
        let executable = EpicLibrary.drive.appendingPathComponent(game.programPath)
        let savedProfile = windowsLibrary.profile(for: "epic:\(game.appName)", title: game.title)
        Task { @MainActor in
            do {
                let epicArguments = try await epicLibrary.launchArguments(appName: game.appName)
                var profile = savedProfile
                profile.arguments = [profile.arguments, epicArguments].filter { !$0.isEmpty }.joined(separator: " ")
                coordinator.launchWindowsExecutable(at: executable, profile: profile)
            } catch {
                installMessage = error.localizedDescription
                isShowingInstallResult = true
            }
        }
    }

    private func steamProgressAction(for game: SteamAppInfo) -> some View {
        let progress = steamLibrary.downloadProgress[game.appID]
        let checking = progress?.phase == .checking
        let fraction = checking ? (progress.map { $0.checkTotal > 0 ? min(1, Double($0.checkDone) / Double($0.checkTotal)) : 0 } ?? 0) : (progress?.fraction ?? 0)
        let percent = Int((fraction * 100).rounded())
        let label: String
        switch progress?.phase {
        case .preparing: label = tr("Preparing download...")
        case .checking: label = tr("Checking existing files %d%%", percent)
        case .finishing: label = tr("Finishing installation...")
        default: label = tr("Installing %d%%", percent)
        }
        let canStop = steamLibrary.canCancelInstall(appID: game.appID)
        return progressAction(fraction: fraction, label: label,
                              onPause: canStop ? { steamLibrary.pauseInstall(appID: game.appID) } : nil,
                              onStop: canStop ? { steamLibrary.cancelInstall(appID: game.appID) } : nil,
                              stopping: steamLibrary.cancellingApps.contains(game.appID))
    }

    private func resolvePrefixPath() {
        coordinator.containerHost.mountEnvironment { mountedPath in
            guard let mountedPath else { return }
            let root = URL(fileURLWithPath: mountedPath, isDirectory: true)
            Task { @MainActor in
                ExternalDrives.shared.mountAll(prefix: root)
                prefixPath = root
                windowsLibrary.refresh(prefixPath: root)
                let unindexedIcons = Array(windowsLibrary.executableURLs.prefix(40))
                Task(priority: .utility) {
                    for executable in unindexedIcons {
                        await windowsLibrary.importEmbeddedIcon(for: executable)
                    }
                }
                steamLibrary.refreshInstalledApps(prefixPath: root)
                gogLibrary.refreshInstalled(prefixPath: root)
                coordinator.installSteamClientComponentsIfNeeded()
                appManager.refreshInstalledApps()
            }
        }
    }

    /// Looks again for installed games of every store and Windows programs.
    private func reloadInstalledGames() {
        resolvePrefixPath()
        guard let prefixPath else { return }
        steamLibrary.refreshInstalledApps(prefixPath: prefixPath)
        gogLibrary.refreshInstalled(prefixPath: prefixPath)
        epicLibrary.reloadInstalled()
        windowsLibrary.refresh(prefixPath: prefixPath)
    }

    /// JIT must be on before any Windows program starts.
    private func requireJIT() -> Bool {
        coordinator.refreshJITStatus()
        guard coordinator.isJITEnabled else {
            installMessage = tr("Activate JIT with StikDebug, then confirm it in Settings.")
            isShowingInstallResult = true
            return false
        }
        return true
    }

    private func launchGOGGame(_ game: GOGInstalledGame) {
        guard requireJIT() else { return }
        var profile = windowsLibrary.profile(for: "gog:\(game.gameID)", title: game.name)
        if profile.arguments.isEmpty { profile.arguments = game.arguments }
        coordinator.launchWindowsExecutable(at: game.executable, profile: profile)
    }

    /// Installs a GOG game from GOG's content system (the game's own files,
    /// no installer). Games without a Galaxy build fall back to the offline
    /// installer, run without any installer windows.
    private func downloadGOGInstaller(_ game: GOGGame) {
        guard let prefixPath else { return }
        gogLibrary.install(game, prefixPath: prefixPath) { outcome in
            windowsLibrary.refresh(prefixPath: prefixPath)
            guard case .installer(let setup) = outcome else { return }
            coordinator.refreshJITStatus()
            guard coordinator.isJITEnabled else {
                installMessage = tr("The %@ installer is ready under Installed games as %@. Run it to install the game; it then appears with the GOG mark.",
                                    game.title, setup.deletingPathExtension().lastPathComponent)
                isShowingInstallResult = true
                return
            }
            let profile = WindowsGameProfile(id: "gog-setup:\(game.id)", title: game.title,
                                             arguments: GOGLibraryModel.silentInstallArguments(for: game))
            coordinator.launchWindowsExecutable(at: setup, profile: profile)
        }
    }

    private func launchSteamGame(_ game: SteamAppInfo) {
        guard let prefixPath else {
            installMessage = tr("Windows environment is not ready.")
            isShowingInstallResult = true
            return
        }
        let profile = windowsLibrary.profile(for: "steam:\(game.appID)", title: game.name)
        if MadeiraBundleIdentity.isNative,
           let warning = coordinator.steamLaunchWarning(game: game, prefixPath: prefixPath) {
            steamCompatibilityMessage = warning
            pendingSteamCompatibilityLaunch = (game: game, profile: profile, prefixPath: prefixPath)
            showingSteamCompatibilityWarning = true
            return
        }
        coordinator.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath)
        if coordinator.windowsStatus.hasPrefix("Cannot launch") || coordinator.windowsStatus.hasPrefix("Madeira runtime missing") {
            installMessage = trStatus(coordinator.windowsStatus)
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


/// A GOG cover: tries each candidate URL in turn, then a plain tile.
private struct GOGArtworkView: View {
    let urls: [URL]
    let fallbackColor: Color
    @State private var index = 0

    var body: some View {
        Group {
            if index < urls.count {
                AsyncImage(url: urls[index]) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Color.clear.onAppear { index += 1 }
                    default:
                        fallbackColor.overlay(ProgressView().tint(.gray))
                    }
                }
                .id(index)
            } else {
                fallbackColor.overlay(
                    Image(systemName: "gamecontroller")
                        .font(.largeTitle)
                        .foregroundColor(.gray))
            }
        }
        // Take the size the card gives (the same 2:3 frame as a Steam cover)
        // and crop to it, as SteamGameArtworkView does: a filled image is
        // otherwise drawn larger than its frame and spills out of it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    @State private var dataSelection = GuestContainerSelection()
    @State private var containerName = ""
    @State private var containerToDelete: GuestDataContainer?
    @State private var confirmContainerDeletion = false

    private var containerKey: String { appManager.bundleIdentifier(for: appURL) ?? appURL.lastPathComponent }

    private func updateContainers(_ action: () throws -> Void) {
        do {
            try action()
            dataSelection = try GuestContainerStore.shared.selection(for: containerKey)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private var containerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Data containers")).font(.headline)
            Text(tr("Data is preserved when updating or uninstalling the app. Delete containers separately."))
                .font(.caption).foregroundColor(.secondary)
            ForEach(dataSelection.containers) { container in
                HStack {
                    Button {
                        updateContainers { try GuestContainerStore.shared.select(container.id, for: containerKey) }
                    } label: {
                        Label(container.name, systemImage: dataSelection.selected == container.id ? "checkmark.circle.fill" : "circle")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        containerToDelete = container
                        confirmContainerDeletion = true
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel(tr("Delete container"))
                }
            }
            TextField(tr("Container name"), text: $containerName).textFieldStyle(.roundedBorder)
            HStack {
                Button(tr("Create container")) {
                    updateContainers {
                        try GuestContainerStore.shared.create(for: containerKey, name: containerName)
                        containerName = ""
                    }
                }
                Button(tr("Rename selected")) {
                    guard let selected = dataSelection.selected else { return }
                    updateContainers {
                        try GuestContainerStore.shared.rename(selected, for: containerKey, name: containerName)
                        containerName = ""
                    }
                }.disabled(dataSelection.selected == nil)
            }.disabled(containerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(tr("Container storage is ready. Running iOS apps still requires integration of the LiveContainer loader and signing."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

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
                    containerControls
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
                updateContainers { }
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
            .confirmationDialog(tr("Delete container and all its data?"), isPresented: $confirmContainerDeletion, titleVisibility: .visible) {
                Button(tr("Delete container"), role: .destructive) {
                    guard let container = containerToDelete else { return }
                    updateContainers { try GuestContainerStore.shared.remove(container.id, for: containerKey) }
                    containerToDelete = nil
                }
                Button(tr("Cancel"), role: .cancel) { containerToDelete = nil }
            }
            .alert(tr("Error"), isPresented: $showError) {
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
                    WindowsGameProfileForm(profile: $profile)
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
                    Button {
                        library.save(profile)
                        dismiss()
                    } label: {
                        Label(tr("Save"), systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
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
                    SteamGameBannerView(game: game)
                        .frame(maxWidth: .infinity)
                    Text(game.name)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        DetailChip(text: installed ? tr("Installed") : tr("Not installed"),
                                   systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                                   tint: installed ? .green : .gray)
                        if let size = installedSizeText {
                            DetailChip(text: size, systemImage: "internaldrive", tint: .gray)
                        }
                    }
                    if steamLibrary.pausedInstalls.contains(game.appID) {
                        VStack(spacing: 10) {
                            Text(tr("Download paused")).foregroundColor(.white)
                            Button {
                                steamLibrary.resumeInstall(appID: game.appID)
                            } label: {
                                Label(tr("Resume"), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button(role: .destructive) {
                                steamLibrary.cancelInstall(appID: game.appID)
                            } label: {
                                Label(tr("Stop download"), systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if installing {
                        downloadStatus
                    } else if installed {
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

                    if let error = steamLibrary.downloadErrors[game.appID] {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    WindowsGameProfileForm(profile: $profile)
                    DetailCard(title: tr("Steam Cloud saves"),
                               footer: steamLibrary.cloudMessages[game.appID]
                                   ?? tr("Automatically sync Steam Cloud saves before playing when available. Conflicting saves are never overwritten.")) {
                        steamCloudControls
                    }
                    if installed {
                        DetailCard(title: tr("DLCs")) {
                            dlcList
                        }
                    }
                }
                .padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Game details"))
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: IRelayDeviceService.installedNotification)) { _ in
                if let prefixPath { steamLibrary.refreshInstalledDLC(appID: game.appID, prefixPath: prefixPath) }
            }
            .onChange(of: steamLibrary.installingDLC[game.appID]) { _, now in
                if now == nil, let prefixPath { steamLibrary.refreshInstalledDLC(appID: game.appID, prefixPath: prefixPath) }
            }
            .task(id: game.appID) {
                await steamLibrary.loadDLC(appID: game.appID)
                guard !Task.isCancelled else { return }
                if let prefixPath {
                    steamLibrary.refreshInstalledDLC(appID: game.appID, prefixPath: prefixPath)
                    guard !Task.isCancelled else { return }
                    if autoSaveEnabled {
                        await steamLibrary.syncCloud(appID: game.appID, prefixPath: prefixPath)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        library.save(profile)
                        dismiss()
                    } label: {
                        Label(tr("Save"), systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
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

    @AppStorage(SteamCloudAutoSave.key) private var autoSaveEnabled = false

    /// Size on disk when installed; otherwise what the account's own
    /// edition takes once installed (or, failing that, its download size).
    private var installedSizeText: String? {
        var bytes: UInt64 = 0
        if installed { bytes = steamLibrary.installedSizes[game.appID] ?? 0 }
                if bytes == 0 { bytes = game.downloadSize(for: "windows") }
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private var steamCloudControls: some View {
        let syncing = steamLibrary.cloudSyncing.contains(game.appID)
        return VStack(spacing: 0) {
            DetailRow(title: tr("Auto Save"), icon: "icloud.fill", iconColor: .blue) {
                if syncing { ProgressView() }
                Toggle(tr("Auto Save"), isOn: $autoSaveEnabled).labelsHidden().tint(.green)
            }
            if steamLibrary.cloudConflicts.contains(game.appID) {
                DetailRow(title: tr("Conflicting saves: choose which copy to keep. The replaced copy will be backed up."),
                          icon: "exclamationmark.triangle.fill", iconColor: .orange) { EmptyView() }
                DetailButtonRow(title: tr("Use Steam Cloud saves"), systemImage: "icloud.and.arrow.down") {
                    guard let prefixPath else { return }
                    Task { await steamLibrary.resolveCloud(appID: game.appID, prefixPath: prefixPath, preferCloud: true) }
                }
                .disabled(prefixPath == nil || syncing)
                DetailButtonRow(title: tr("Use local saves"), systemImage: "internaldrive") {
                    guard let prefixPath else { return }
                    Task { await steamLibrary.resolveCloud(appID: game.appID, prefixPath: prefixPath, preferCloud: false) }
                }
                .disabled(prefixPath == nil || syncing)
            }
            DetailButtonRow(title: tr("Sync saves now"), systemImage: "arrow.triangle.2.circlepath.icloud",
                            showsDivider: false) {
                guard let prefixPath else { return }
                Task { await steamLibrary.syncCloud(appID: game.appID, prefixPath: prefixPath) }
            }
            .disabled(prefixPath == nil || syncing)
        }
    }

    private var downloadStatus: some View {
        let progress = steamLibrary.downloadProgress[game.appID]
        let stopping = steamLibrary.cancellingApps.contains(game.appID)
        return VStack(spacing: 10) {
            ProgressView(value: progress?.phase == .checking
                         ? (progress.map { $0.checkTotal > 0 ? min(1, Double($0.checkDone) / Double($0.checkTotal)) : 0 } ?? 0)
                         : (progress?.fraction ?? 0))
            Text(progress?.phase == .preparing ? tr("Preparing download...") :
                 progress?.phase == .checking ? tr("Checking existing files %d%%", Int(((progress.map { $0.checkTotal > 0 ? min(1, Double($0.checkDone) / Double($0.checkTotal)) : 0 } ?? 0) * 100).rounded())) :
                 progress?.phase == .finishing ? tr("Finishing installation...") :
                 tr("Installing %d%%", Int(((progress?.fraction ?? 0) * 100).rounded())))
                .font(.caption)
                .foregroundColor(.white)
            if let progress, progress.installedBytes > 0 {
                Text(tr("Installed: %@", ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: progress.installedBytes), countStyle: .file)))
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            if steamLibrary.canCancelInstall(appID: game.appID) {
                Button {
                    steamLibrary.pauseInstall(appID: game.appID)
                } label: {
                    Label(tr("Pause download"), systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(stopping)
                .buttonStyle(.bordered)
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

    /// A DLC's size: its own depots in the game's app info (where Steam lists
    /// DLC content), else the DLC app's own download size.
    private func dlcSize(_ id: UInt32) -> String? {
        var bytes = game.depots.filter { $0.dlcAppID == id }.reduce(UInt64(0)) { $0 + max($1.maxSize, $1.publicSizeBytes) }
        if bytes == 0 { bytes = steamLibrary.dlcMetadata[id]?.downloadSize(for: "windows") ?? 0 }
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private var dlcList: some View {
        VStack(spacing: 0) {
            let ids = steamLibrary.availableDLC[game.appID] ?? []
            if ids.isEmpty {
                DetailRow(title: tr("No DLC found for this game"), showsDivider: false) { EmptyView() }
            }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 12) {
                    SteamDLCArtworkView(appID: id)
                        .frame(width: 92, height: 43)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(steamLibrary.dlcMetadata[id]?.name ?? "DLC \(id)")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        if let size = dlcSize(id) {
                            Text(size)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        if steamLibrary.installingDLC[game.appID] == id {
                            let fraction = steamLibrary.downloadProgress[game.appID]?.fraction ?? 0
                            ProgressView(value: fraction)
                                .tint(.blue)
                            Text(tr("Installing %d%%", Int((fraction * 100).rounded())))
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                    }
                    Spacer(minLength: 6)
                    if steamLibrary.installingDLC[game.appID] == id {
                        Button(role: .destructive) {
                            steamLibrary.cancelDLCInstall(appID: game.appID, dlcAppID: id)
                        } label: {
                            Label(tr("Cancel"), systemImage: "xmark.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(steamLibrary.cancellingDLC.contains(id))
                    } else if steamLibrary.installedDLC[game.appID]?.contains(id) == true {
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
                            steamLibrary.startDLCInstall(appID: game.appID,
                                                        dlcAppID: id, prefixPath: prefixPath)
                        } label: {
                            Text(tr("Install"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(steamLibrary.installingApps.contains(game.appID))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if id != ids.last {
                    Divider().background(Color.white.opacity(0.08)).padding(.leading, 68)
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailCard(title: tr("Display")) {
                DetailPickerRow(title: tr("Resolution"), selection: $profile.resolution,
                                choices: ["Device native", "960x540", "1280x720", "1600x900", "1920x1080"],
                                icon: "rectangle.on.rectangle", iconColor: .blue)
                DetailPickerRow(title: tr("Surface scaling"), selection: $profile.surfaceScaling,
                                choices: ["fit", "fill", "stretch", "aspect"],
                                icon: "arrow.up.left.and.arrow.down.right", iconColor: .blue)
                DetailPickerRow(title: tr("Frame rate limit"), selection: $profile.fpsLimit,
                                choices: WindowsGameProfile.fpsLimits,
                                icon: "speedometer", iconColor: .orange)
                DetailToggleRow(title: tr("MetalFX upscaling"), isOn: $profile.metalFXEnabled, showsDivider: false,
                                icon: "sparkles", iconColor: .purple)
            }
            DetailCard(title: tr("Graphics"),
                       footer: tr("Direct3D 11 and Direct3D 12 are chosen automatically for each game.")) {
                DetailPickerRow(title: tr("Direct3D 12"), selection: $profile.d3d12Renderer,
                                choices: WindowsGameProfile.d3d12Renderers,
                                icon: "cube.transparent.fill", iconColor: .indigo)
                DetailPickerRow(title: tr("Vulkan"), selection: $profile.vulkanMode, choices: WindowsGameProfile.vulkanModes,
                                icon: "flame.fill", iconColor: .red)
                DetailPickerRow(title: tr("OpenGL"), selection: $profile.openGLBackend,
                                choices: WindowsGameProfile.openGLBackends, showsDivider: false,
                                icon: "circle.hexagongrid.fill", iconColor: .teal)
            }
            DetailCard(title: tr("Controls")) {
                DetailPickerRow(title: tr("Controller API"), selection: $profile.controllerAPI,
                                choices: ["Automatic", "XInput", "XInput + DirectInput", "HID", "DualSense HID", "Generic HID"],
                                showsDivider: false, icon: "gamecontroller.fill", iconColor: .green)
            }
            DetailCard(title: tr("Performance")) {
                DetailPickerRow(title: tr("CPU cores"), selection: Binding(
                                    get: { profile.cpuCount == 0 ? tr("All") : String(profile.cpuCount) },
                                    set: { profile.cpuCount = Int($0) ?? 0 }),
                                choices: WindowsGameProfile.cpuCounts.map { $0 == 0 ? tr("All") : String($0) },
                                icon: "cpu", iconColor: .blue)
                DetailToggleRow(title: tr("Fast synchronization"), isOn: $profile.fastSync,
                                icon: "bolt.fill", iconColor: .yellow)
                DetailToggleRow(title: tr("Frame generation"), isOn: $profile.frameGeneration, showsDivider: false,
                                icon: "film.stack", iconColor: .purple)
            }
            DetailCard(title: tr("Compatibility"),
                       footer: tr("Games iDeck recognises get the settings they were tested with.")) {
                DetailToggleRow(title: tr("Use recommended settings"), isOn: $profile.useRecommended,
                                icon: "checkmark.seal.fill", iconColor: .green)
                DetailPickerRow(title: tr("Code checks"), selection: $profile.codeChecks,
                                choices: WindowsGameProfile.codeCheckModes,
                                icon: "checkmark.shield.fill", iconColor: .orange)
                DetailToggleRow(title: tr("Keep helper processes running"),
                                isOn: $profile.keepChildProcessesRunning,
                                icon: "square.stack.3d.up.fill", iconColor: .gray)
                DetailButtonRow(title: tr("Reset to Recommended"), systemImage: "arrow.counterclockwise",
                                showsDivider: false) {
                    GameRecommendations.applySwitches(for: profile.id, to: &profile)
                }
            }
            DetailCard(title: tr("Launch arguments")) {
                TextField(tr("Example: -windowed"), text: $profile.arguments)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
            }
        }
    }
}

// MARK: - GOG and Epic game details

/// The game page shared by GOG and Epic: the same banner, cover, title,
/// actions and per-game settings as a Steam game's page. Store-specific
/// rows (Epic's version, update, repair, cloud saves) go in `extra`.
private struct StoreGameDetailsView<Extra: View>: View {
    let title: String
    let store: GameStore
    let profileID: String
    let covers: [URL]
    let banners: [URL]
    let installed: Bool
    /// Install progress 0...1 while downloading or installing.
    let progress: Double?
    let paused: Bool
    let sizeText: String?
    let errorText: String?
    let canInstall: Bool
    let onLaunch: () -> Void
    let onInstall: () -> Void
    let onPause: (() -> Void)?
    let onStop: () -> Void
    let onUninstall: (() -> Bool)?
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    @ViewBuilder var extra: Extra
    @Environment(\.dismiss) private var dismiss
    @State private var profile: WindowsGameProfile
    @State private var confirmUninstall = false
    @State private var errorMessage: String?

    init(title: String, store: GameStore, profileID: String, covers: [URL], banners: [URL],
         installed: Bool, progress: Double?, paused: Bool = false, sizeText: String?, errorText: String?,
         canInstall: Bool, onLaunch: @escaping () -> Void, onInstall: @escaping () -> Void,
         onPause: (() -> Void)? = nil, onStop: @escaping () -> Void, onUninstall: (() -> Bool)?,
         library: WindowsLibraryStore, coordinator: SystemCoordinator,
         @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.store = store
        self.profileID = profileID
        self.covers = covers
        self.banners = banners
        self.installed = installed
        self.progress = progress
        self.paused = paused
        self.sizeText = sizeText
        self.errorText = errorText
        self.canInstall = canInstall
        self.onLaunch = onLaunch
        self.onInstall = onInstall
        self.onPause = onPause
        self.onStop = onStop
        self.onUninstall = onUninstall
        self.library = library
        self.coordinator = coordinator
        self.extra = extra()
        var initial = library.profile(for: profileID, title: title)
        _profile = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    StoreBannerView(urls: banners + covers)
                    Text(title)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack(spacing: 8) {
                        DetailChip(text: installed ? tr("Installed") : tr("Not installed"),
                                   systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                                   tint: installed ? .green : .gray)
                        DetailChip(text: sizeText ?? tr("Calculating..."), systemImage: "internaldrive", tint: .gray)
                    }

                    actions

                    if let errorText {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    WindowsGameProfileForm(profile: $profile)
                    extra
                }
                .padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Game details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Done")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        library.save(profile)
                        dismiss()
                    } label: {
                        Label(tr("Save"), systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
            .confirmationDialog(tr("Delete this game's files?"), isPresented: $confirmUninstall, titleVisibility: .visible) {
                Button(tr("Uninstall"), role: .destructive) {
                    if onUninstall?() == true {
                        library.removeProfile(for: profileID)
                        dismiss()
                    } else {
                        errorMessage = tr("Could not remove this game's files.")
                    }
                }
                Button(tr("Cancel"), role: .cancel) {}
            }
            .alert(tr("Operation failed"), isPresented: Binding(get: { errorMessage != nil },
                                                                 set: { if !$0 { errorMessage = nil } })) {
                Button(tr("OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var actions: some View {
        if let progress, !paused {
            VStack(spacing: 10) {
                ProgressView(value: progress)
                Text(tr("Installing %d%%", Int((progress * 100).rounded())))
                    .font(.caption)
                    .foregroundColor(.white)
                if let onPause {
                    Button(action: onPause) {
                        Label(tr("Pause download"), systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive, action: onStop) {
                    Label(tr("Stop download"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } else if installed {
            if onUninstall != nil {
                Button(role: .destructive) { confirmUninstall = true } label: {
                    Label(tr("Uninstall"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        } else if canInstall {
            Button(action: onInstall) {
                Label(tr(paused ? "Resume" : "Install"),
                      systemImage: paused ? "play.circle.fill" : "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Text(tr("Not available for Windows"))
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

/// GOG game page.
private struct GOGGameDetailsSheet: View {
    let game: GOGGame
    let prefixPath: URL?
    @ObservedObject var gog: GOGLibraryModel
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    let launch: (GOGInstalledGame) -> Void
    let install: (GOGGame) -> Void

    private var sizeText: String? {
        let bytes = gog.installedSizes[game.id] ?? gog.downloadSizes[game.id] ?? 0
        if bytes == 0 && gog.downloadSizes[game.id] != nil && gog.installed[game.id] == nil { return tr("Size unavailable") }
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }

    var body: some View {
        let installed = gog.installed[game.id]
        StoreGameDetailsView(
            title: game.title, store: .gog, profileID: "gog:\(game.id)",
            covers: game.artworkCandidates, banners: GOGLibraryModel.bannerCandidates(game),
            installed: installed != nil, progress: gog.downloadProgress[game.id],
            paused: gog.pausedDownloads.contains(game.id),
            sizeText: sizeText, errorText: gog.downloadErrors[game.id].map { tr($0) },
            canInstall: game.worksOnWindows && prefixPath != nil,
            onLaunch: { if let installed { launch(installed) } },
            onInstall: {
                if gog.pausedDownloads.contains(game.id) { gog.resumeDownload(game) }
                else { install(game) }
            },
            onPause: { gog.pauseDownload(game) },
            onStop: { gog.cancelDownload(game) },
            onUninstall: prefixPath.map { prefix in { gog.uninstall(game.id, prefixPath: prefix) } },
            library: library, coordinator: coordinator
        ) { EmptyView() }
        .task(id: game.id) { await gog.loadSize(for: game) }
    }
}

/// Epic game page.
private struct EpicGameDetailsSheet: View {
    let appName: String
    @ObservedObject var epic: EpicLibrary
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    let launch: (EpicInstalledGame) -> Void

    private var title: String { epic.game(appName)?.title ?? epic.installed[appName]?.title ?? "Epic Games" }

    private var sizeText: String? {
        let bytes = epic.installed[appName]?.installBytes ?? epic.manifestSizes[appName] ?? 0
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
    }

    var body: some View {
        let installed = epic.installed[appName]
        let download = epic.downloads[appName]
        let failed: String? = { if case .failed(let message) = download?.state { return message }; return nil }()
        let paused: Bool = { if case .paused = download?.state { return true }; return false }()
        StoreGameDetailsView(
            title: title, store: .epic, profileID: "epic:\(appName)",
            covers: [epic.game(appName)?.cover].compactMap { $0 },
            banners: [epic.game(appName)?.wide].compactMap { $0 },
            installed: installed != nil && download == nil,
            progress: (download != nil && failed == nil) ? download?.progress.fraction : nil,
            paused: paused, sizeText: sizeText, errorText: failed,
            canInstall: true,
            onLaunch: { if let installed { launch(installed) } },
            onInstall: { epic.install(appName) },
            onPause: { epic.pause(appName) },
            onStop: { epic.cancel(appName) },
            onUninstall: (epic.sessionRunning || EpicCloud.shared.isBusy) ? nil : { epic.uninstall(appName); return true },
            library: library, coordinator: coordinator
        ) {
            if installed != nil {
                DetailCard(title: "Epic Games") {
                    DetailValueRow(title: tr("Version"), value: installed?.buildVersion ?? "",
                                   icon: "number", iconColor: .gray)
                    if epic.updateAvailable(appName) {
                        DetailButtonRow(title: tr("Update"), systemImage: "arrow.down.circle") { epic.install(appName) }
                    }
                    DetailButtonRow(title: tr("Repair"), systemImage: "wrench.and.screwdriver", showsDivider: false) {
                        epic.repair(appName)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    EpicCloudSection(appName: appName)
                }
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: appName) { await epic.loadSize(appName) }
    }
}


/// A DLC's own cover: its store header first (DLC rarely have a library capsule).
struct SteamDLCArtworkView: View {
    let appID: UInt32
    @State private var index = 0

    private var candidates: [URL] {
        ["header.jpg", "capsule_231x87.jpg", "capsule_616x353.jpg", "library_600x900.jpg"].compactMap {
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\($0)")
        }
    }

    var body: some View {
        AsyncImage(url: index < candidates.count ? candidates[index] : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if phase.error != nil {
                Color.white.opacity(0.08).onAppear { if index < candidates.count { index += 1 } }
            } else {
                Color.white.opacity(0.08)
            }
        }
    }
}

// MARK: - Console-style home (PS-like shelf)

/// One tile of the top shelf: a store, or a game that is installed or installing.
enum ShelfItem: Hashable {
    case store(GameStore)
    case steam(UInt32)
    case gog(Int)
    case gogInstalling(Int)
    case epic(String)
    case epicInstalling(String)
    case exe(String)
}

extension WindowsWorkspaceView {
    /// The games on the shelf, installing ones included, after the stores.
    var shelfGames: [ShelfItem] {
        installedSteamGames.map { .steam($0.appID) }
            + installingGOGGames.map { .gogInstalling($0.id) }
            + installedGOGGames.map { .gog($0.gameID) }
            + installingEpicGames.map { .epicInstalling($0.appName) }
            + installedEpicGames.map { .epic($0.appName) }
            + windowsLibrary.executableURLs.map { .exe($0.path) }
    }

    /// The selected tile, or the Steam store when it no longer exists.
    var currentShelf: ShelfItem {
        if case .store = shelf { return shelf }
        return shelfGames.contains(shelf) ? shelf : .store(.steam)
    }

    var consoleShelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: isCompact ? 10 : 14) {
                    ForEach([GameStore.steam, .gog, .epic], id: \.self) { store in
                        shelfTile(.store(store))
                    }
                    if !shelfGames.isEmpty {
                        Rectangle().fill(lineColor).frame(width: 1, height: shelfTileHeight * 0.7)
                            .padding(.top, shelfTileHeight * 0.15)
                    }
                    ForEach(shelfGames, id: \.self) { item in
                        shelfTile(item)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
            }
            .onChange(of: shelf) { _, item in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(item, anchor: .center) }
            }
        }
    }

    private var shelfTileWidth: CGFloat { isCompact ? 64 : 78 }
    private var shelfTileHeight: CGFloat { isCompact ? 86 : 104 }

    private func shelfTile(_ item: ShelfItem) -> some View {
        let selected = currentShelf == item
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { shelf = item }
        } label: {
            VStack(spacing: 6) {
                shelfArtwork(item)
                    .frame(width: shelfTileWidth, height: shelfTileHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? textColor : lineColor, lineWidth: selected ? 2 : 1))
                    .overlay(alignment: .bottom) { shelfProgress(item) }
                    .scaleEffect(selected ? 1.08 : 1)
                    .shadow(color: selected ? accentColor.opacity(0.45) : .clear, radius: 10)
                Text(shelfTitle(item))
                    .multilineTextAlignment(.center)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? textColor : faintColor)
                    .lineLimit(1)
                    .frame(width: shelfTileWidth + 8)
            }
        }
        .buttonStyle(.plain)
        .id(item)
        .accessibilityLabel(shelfTitle(item))
    }

    @ViewBuilder
    private func shelfArtwork(_ item: ShelfItem) -> some View {
        switch item {
        case .store(let store):
            ZStack {
                panelColor
                Image(storeAsset(store))
                    .renderingMode(store == .steam ? .original : .template)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(textColor)
                    .padding(shelfTileWidth * 0.22)
            }
        case .steam(let id):
            if let game = steamLibrary.games.first(where: { $0.appID == id }) {
                SteamGameArtworkView(game: game)
            } else { panelColor }
        case .gog(let id), .gogInstalling(let id):
            GOGArtworkView(urls: gogLibrary.games.first { $0.id == id }?.artworkCandidates ?? [], fallbackColor: panelColor)
        case .epic(let app), .epicInstalling(let app):
            GOGArtworkView(urls: [epicLibrary.game(app)?.cover].compactMap { $0 }, fallbackColor: panelColor)
        case .exe(let path):
            WindowsExecutableArtworkView(executableURL: URL(fileURLWithPath: path), library: windowsLibrary, fallbackColor: panelColor)
        }
    }

    /// A thin bar on a tile whose game is downloading.
    @ViewBuilder
    private func shelfProgress(_ item: ShelfItem) -> some View {
        if let fraction = shelfDownloadFraction(item) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.6))
                    Rectangle().fill(accentColor).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())
            .padding(6)
        }
    }

    private func shelfDownloadFraction(_ item: ShelfItem) -> Double? {
        switch item {
        case .steam(let id):
            guard steamLibrary.installingApps.contains(id) else { return nil }
            guard let progress = steamLibrary.downloadProgress[id], progress.totalBytes > 0 else { return 0 }
            return Double(progress.doneBytes) / Double(progress.totalBytes)
        case .gogInstalling, .epicInstalling:
            return 0.5
        default:
            return nil
        }
    }

    private func storeAsset(_ store: GameStore) -> String {
        switch store {
        case .steam: return "StoreBadgeSteam"
        case .gog: return "StoreBadgeGOG"
        case .epic: return "StoreBadgeEpic"
        }
    }

    private func shelfTitle(_ item: ShelfItem) -> String {
        switch item {
        case .store(.steam): return "Steam"
        case .store(.gog): return "GOG"
        case .store(.epic): return "Epic Games"
        case .steam(let id): return steamLibrary.games.first { $0.appID == id }?.name ?? "Steam"
        case .gog(let id): return gogLibrary.installed[id]?.name ?? "GOG"
        case .gogInstalling(let id): return gogLibrary.games.first { $0.id == id }?.title ?? "GOG"
        case .epic(let app): return epicLibrary.installed[app]?.title ?? "Epic"
        case .epicInstalling(let app): return epicLibrary.game(app)?.title ?? "Epic"
        case .exe(let path): return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    // MARK: Content under the shelf

    @ViewBuilder
    var shelfContent: some View {
        switch currentShelf {
        case .store(let store): storePage(store)
        default: gamePage(currentShelf)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.gray)
            TextField(tr("Search your games"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundColor(.white)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(panelColor)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(lineColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// A store: its games to install, and their DLC in the game's page.
    @ViewBuilder
    private func storePage(_ store: GameStore) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                searchField
                Button { refreshAllLibraries() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                        .foregroundColor(textColor)
                        .frame(width: 42, height: 42)
                        .background(panelColor)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(lineColor, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .disabled(mixedLibraryLoading)
                .accessibilityLabel(tr("Refresh"))
            }
            switch store {
            case .steam:
                if coordinator.isSteamConnected {
                    storeGrid(loading: steamLibrary.isLoading, error: steamLibrary.errorMessage.map { tr($0) },
                              count: steamLibrary.games.count, entries: filteredSteamGames.map { .steam($0) })
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(tr("Connect Steam to continue"), systemImage: "steam")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(tr("Sign in directly with Steam. iDeck does not store your password; the sign-in token is saved in this device's Keychain."))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(panelColor)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            case .gog:
                if gogLibrary.isSignedIn {
                    storeGrid(loading: gogLibrary.isLoading, error: gogLibrary.errorMessage.map { tr($0) },
                              count: gogLibrary.games.count, entries: filteredGOGGames.map { .gog($0) })
                } else {
                    gogContent
                }
            case .epic:
                if epicLibrary.signedIn {
                    storeGrid(loading: epicLibrary.refreshing, error: epicLibrary.error,
                              count: epicLibrary.owned.count, entries: filteredEpicGames.map { .epic($0) })
                } else {
                    epicContent
                }
            }
        }
    }

    @ViewBuilder
    private func storeGrid(loading: Bool, error: String?, count: Int, entries: [MixedLibraryEntry]) -> some View {
        if loading { ProgressView().tint(.white) }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .lineLimit(2)
        }
        let sorted = entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if sorted.isEmpty {
            if !loading {
                Text(count == 0 ? tr("No games") : tr("No games match this search"))
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(sorted) { entry in
                    switch entry {
                    case .steam(let game): gameCard(game)
                    case .gog(let game): gogCard(game)
                    case .epic(let game): epicCard(game)
                    }
                }
            }
        }
    }

    /// An installed (or installing) game: big art, Play and its settings.
    @ViewBuilder
    private func gamePage(_ item: ShelfItem) -> some View {
        VStack(alignment: .center, spacing: 16) {
            gameHero(item)
                .frame(maxWidth: .infinity)
                .frame(height: isCompact ? 180 : 260)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(lineColor, lineWidth: 1))
            Text(shelfTitle(item))
                .font(.system(size: isCompact ? 22 : 28, weight: .semibold))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 10) {
                gameAction(item)
                    .frame(maxWidth: 320)
                if hasSettings(item) {
                    Button { openSettings(item) } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.headline)
                            .foregroundColor(textColor)
                            .frame(width: cardActionHeight, height: cardActionHeight)
                            .background(panelColor)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineColor, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(tr("Settings"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func gameHero(_ item: ShelfItem) -> some View {
        switch item {
        case .steam(let id):
            if let game = steamLibrary.games.first(where: { $0.appID == id }) {
                SteamGameBannerView(game: game)
            } else { panelColor }
        default:
            shelfArtwork(item)
        }
    }

    @ViewBuilder
    private func gameAction(_ item: ShelfItem) -> some View {
        switch item {
        case .steam(let id):
            if let game = steamLibrary.games.first(where: { $0.appID == id }) {
                if steamLibrary.pausedInstalls.contains(id) {
                    Button { steamLibrary.resumeInstall(appID: id) } label: {
                        cardActionLabel(tr("Resume"), systemImage: "play.circle.fill")
                    }
                } else if steamLibrary.installingApps.contains(id) {
                    steamProgressAction(for: game)
                } else {
                    Button { launchSteamGame(game) } label: { cardActionLabel(tr("Launch"), systemImage: "play.fill") }
                }
            }
        case .gog(let id):
            if let game = gogLibrary.installed[id] {
                Button { launchGOGGame(game) } label: { cardActionLabel(tr("Launch"), systemImage: "play.fill") }
            }
        case .gogInstalling(let id):
            if let game = gogLibrary.games.first(where: { $0.id == id }) { gogCard(game) }
        case .epic(let app):
            if let game = epicLibrary.installed[app] {
                Button { launchEpicGame(game) } label: { cardActionLabel(tr("Launch"), systemImage: "play.fill") }
            }
        case .epicInstalling(let app):
            if let game = epicLibrary.owned.first(where: { $0.appName == app }) { epicCard(game) }
        case .exe(let path):
            Button {
                guard requireJIT() else { return }
                let url = URL(fileURLWithPath: path)
                let profile = windowsLibrary.profile(for: windowsLibrary.profileID(for: url),
                                                     title: url.deletingPathExtension().lastPathComponent)
                coordinator.launchWindowsExecutable(at: url, profile: profile)
            } label: { cardActionLabel(tr("Launch"), systemImage: "play.fill") }
        case .store:
            EmptyView()
        }
    }

    private func hasSettings(_ item: ShelfItem) -> Bool {
        switch item {
        case .steam, .epic, .exe: return true
        case .gog(let id): return gogLibrary.games.contains { $0.id == id }
        default: return false
        }
    }

    private func openSettings(_ item: ShelfItem) {
        switch item {
        case .steam(let id):
            if let game = steamLibrary.games.first(where: { $0.appID == id }) { selectedSteamGame = SelectedSteamGame(game: game) }
        case .gog(let id):
            selectedGOGGame = gogLibrary.games.first { $0.id == id }
        case .epic(let app):
            selectedEpicGame = SelectedEpicGame(id: app)
        case .exe(let path):
            selectedExecutable = SelectedLibraryURL(url: URL(fileURLWithPath: path))
        default:
            break
        }
    }
}
