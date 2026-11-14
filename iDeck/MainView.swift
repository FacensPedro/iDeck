import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.scenePhase) private var scenePhase
    // Lazily retained: a download remains owned when navigating home, but
    // the Steam session is not constructed during process cold-start.
    @State private var steamLibrary: SteamOwnedGamesModel?
    @AppStorage("firstRunSetup.complete.v1") private var firstRunSetupComplete = false
    @State private var isFirstRunSetupPresented = false

    var body: some View {
        Group {
            if let steamLibrary {
                WindowsWorkspaceView(coordinator: coordinator, steamLibrary: steamLibrary)
            } else {
                Color.black.ignoresSafeArea()
                    .task {
                        await Task.yield()
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
            // A new IPA can bring a new Windows runtime: the setup downloads it again.
            if firstRunSetupComplete && MadeiraRuntime.needsDownload { firstRunSetupComplete = false }
            if !firstRunSetupComplete {
                DispatchQueue.main.async { isFirstRunSetupPresented = true }
            }
        }
        .onChange(of: firstRunSetupComplete) { _, complete in
            if !complete { isFirstRunSetupPresented = true }
        }
        .fullScreenCover(isPresented: $isFirstRunSetupPresented) {
            IDeckFirstRunSetupView(coordinator: coordinator) {
                firstRunSetupComplete = true
                isFirstRunSetupPresented = false
            }
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
                // JIT cannot change under a running game, which needs it: skip
                // the sysctl/code-signing probe and its UI refresh meanwhile.
                if !ideck_wineprocess_running() { coordinator.refreshJITStatus() }
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
        if game.appID == 407530 {
            // ARK: Survival of the Fittest publishes its vertical artwork as portrait.png.
            append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/407530/portrait.png"))
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
        Group {
            if imageIndex < urls.count {
                ArtworkImage(url: urls[imageIndex], failed: { imageIndex += 1 }) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ZStack {
                        Color.white.opacity(0.06)
                        ProgressView().tint(.gray)
                    }
                }
                .id(imageIndex)
            } else {
                Color.white.opacity(0.06)
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
    @ObservedObject var steamLibrary: SteamOwnedGamesModel

    @State private var isSettingsPresented = false
    @State private var searchText = ""
    /// The selected tile of the console-style shelf (a store or a game).
    @State var shelf: ShelfItem = .store(.steam)
    @State private var prefixPath: URL?
    @StateObject private var windowsLibrary = WindowsLibraryStore()
    @State private var isExecutablePickerPresented = false
    @State private var isExecutableMenuPresented = false
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
    @State private var isEASignInPresented = false
    @ObservedObject private var eaLibrary = EALibrary.shared
    @State private var selectedEpicGame: SelectedEpicGame?
    @State private var selectedEAGame: EAOwnedGame?
    @State private var selectedGOGGame: GOGGame?
    @AppStorage("library.epicOwnedCollapsed") private var epicOwnedCollapsed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Palette: panel #0b0b0d, card #111114, line #1f1f24.
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

    /// Blur of a cover whose game is not installed.
    private static let uninstalledCoverBlur: CGFloat = 1.5

    /// Madeira's library lattice: 20 pt between columns, 18 pt between rows.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isCompact ? 110 : 154, maximum: 220), spacing: 20)]
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(textColor)
            // Long names wrap to a second line; the height is always two lines, so
            // every card is the same size whatever its title's length.
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .accessibilityLabel(title)
    }

    private func downloadCoverButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image("DownloadCloud")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .padding(8)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Install"))
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
            shelfBackdrop
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .center, spacing: 14) {
                            Spacer(minLength: 8)
                            steamConnectButton
                        }
                        consoleShelf
                        shelfContent
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
        .sheet(isPresented: $isEASignInPresented) {
            EASignInView()
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
        .sheet(item: $selectedEAGame) { game in
            EAGameDetailsSheet(game: game, ea: eaLibrary, library: windowsLibrary,
                               coordinator: coordinator) { installed in launchEAGame(installed) }
        }
        .onAppear {
            epicLibrary.start()
            eaLibrary.start()
        }
        .task(id: gogLibrary.isSignedIn) {
            if gogLibrary.isSignedIn && gogLibrary.games.isEmpty {
                await gogLibrary.refresh()
            }
        }
        .sheet(item: $selectedExecutable) { selection in
            WindowsExecutableDetailsView(executableURL: selection.url, prefixPath: prefixPath, library: windowsLibrary, coordinator: coordinator)
        }
        .sheet(item: $selectedSteamGame) { selection in
            SteamProgramDetailsView(game: selection.game, prefixPath: prefixPath, library: windowsLibrary, steamLibrary: steamLibrary,
                                    coordinator: coordinator) { game in launchSteamGame(game) }
        }
        .fileImporter(
            isPresented: $isExecutablePickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data, UTType(filenameExtension: "msi") ?? .data, .data],
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
        }
        // A finished Wine session may have installed a game (a GOG installer,
        // a setup program): look for new installs whenever Wine stops.
        .onChange(of: coordinator.windowsStatus) { _, _ in
            guard let prefixPath, !ideck_wineprocess_running() else { return }
            gogLibrary.refreshInstalled(prefixPath: prefixPath)
            windowsLibrary.refresh(prefixPath: prefixPath)
        }
        .preferredColorScheme(.dark)
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
            Text("iDeck")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isJITEnabled ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(coordinator.isJITEnabled ? tr("JIT active") : tr("JIT off"))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
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
        case ea(EAOwnedGame)

        var id: String {
            switch self {
            case .steam(let game): return "steam:\(game.appID)"
            case .gog(let game): return "gog:\(game.id)"
            case .epic(let game): return "epic:\(game.id)"
            case .ea(let game): return "ea:\(game.id)"
            }
        }

        var title: String {
            switch self {
            case .steam(let game): return game.name
            case .gog(let game): return game.title
            case .epic(let game): return game.title
            case .ea(let game): return game.title
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
        if eaLibrary.signedIn { entries += filteredEAGames.map { .ea($0) } }
        return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var mixedLibraryCount: Int {
        (coordinator.isSteamConnected ? steamLibrary.games.count : 0) +
        (gogLibrary.isSignedIn ? gogLibrary.games.count : 0) +
        (epicLibrary.signedIn ? epicLibrary.owned.count : 0) +
        (eaLibrary.signedIn ? eaLibrary.owned.count : 0)
    }

    private var mixedLibraryLoading: Bool {
        (coordinator.isSteamConnected && steamLibrary.isLoading) ||
        (gogLibrary.isSignedIn && gogLibrary.isLoading) ||
        (epicLibrary.signedIn && epicLibrary.refreshing) ||
        (eaLibrary.signedIn && eaLibrary.refreshing)
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
        if eaLibrary.signedIn {
            if eaLibrary.refreshing { notices.append((tr("Loading EA app library..."), false)) }
            else if let error = eaLibrary.error { notices.append(("EA app: " + error, true)) }
        }
        return notices
    }

    /// Libraries › reload: Steam, GOG and Epic Games lists and what is installed.
    private func refreshAllLibraries() {
        reloadInstalledGames()
        if coordinator.isSteamConnected { Task { await steamLibrary.refresh(force: true) } }
        if gogLibrary.isSignedIn { Task { await gogLibrary.refresh() } }
        if epicLibrary.signedIn { Task { await epicLibrary.refreshLibrary() } }
        if eaLibrary.signedIn { Task { await eaLibrary.refreshLibrary() } }
    }

    private func gameCard(_ game: SteamAppInfo) -> some View {
        let installed = steamLibrary.installedApps.contains(game.appID)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Button { selectedSteamGame = SelectedSteamGame(game: game) } label: {
                        SteamGameArtworkView(game: game)
                            .libraryCoverFrame()
                            .blur(radius: !installed && !steamLibrary.installingApps.contains(game.appID) && !steamLibrary.pausedInstalls.contains(game.appID) && game.installableOnWindows ? Self.uninstalledCoverBlur : 0)
                    }
                    .buttonStyle(.plain)
                    if !installed && !steamLibrary.installingApps.contains(game.appID) &&
                        !steamLibrary.pausedInstalls.contains(game.appID) && game.installableOnWindows {
                        downloadCoverButton { install(game) }
                    }
                }
                .libraryCoverFrame()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                Button { selectedSteamGame = SelectedSteamGame(game: game) } label: {
                    cardTitle(game.name.isEmpty ? tr("Untitled Steam app") : game.name)
                }
                .buttonStyle(.plain)
            }

            if !installed, let error = steamLibrary.downloadErrors[game.appID] {
                Text(tr(error))
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
            } else if !installed && !game.installableOnWindows {
                Text(tr("Not available for Windows"))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        LazyVGrid(columns: columns, spacing: 18) {
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
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Button { selectedGOGGame = game } label: {
                        GOGArtworkView(urls: game.artworkCandidates, fallbackColor: secondaryColor, fill: true)
                            .libraryCoverFrame()
                            .blur(radius: installed == nil && gogLibrary.downloadProgress[game.id] == nil &&
                                  !gogLibrary.pausedDownloads.contains(game.id) && game.worksOnWindows ? Self.uninstalledCoverBlur : 0)
                    }
                    .buttonStyle(.plain)
                    if installed == nil && gogLibrary.downloadProgress[game.id] == nil &&
                        !gogLibrary.pausedDownloads.contains(game.id) && game.worksOnWindows {
                        downloadCoverButton { downloadGOGInstaller(game) }
                            .disabled(prefixPath == nil)
                    }
                }
                .libraryCoverFrame()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                Button { selectedGOGGame = game } label: { cardTitle(game.title) }
                    .buttonStyle(.plain)
            }
            if let error = gogLibrary.downloadErrors[game.id] {
                Text(tr(error))
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            if installed == nil && !game.worksOnWindows {
                Text(tr("Not available for Windows"))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        LazyVGrid(columns: columns, spacing: 18) {
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
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Button { selectedEpicGame = SelectedEpicGame(id: game.appName) } label: {
                        GOGArtworkView(urls: [game.cover].compactMap { $0 }, fallbackColor: secondaryColor, fill: true)
                            .libraryCoverFrame()
                            .blur(radius: installed == nil && download == nil ? Self.uninstalledCoverBlur : 0)
                    }
                    .buttonStyle(.plain)
                    if installed == nil && download == nil {
                        downloadCoverButton { epicLibrary.install(game.appName) }
                    }
                }
                .libraryCoverFrame()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                Button { selectedEpicGame = SelectedEpicGame(id: game.appName) } label: { cardTitle(game.title) }
                    .buttonStyle(.plain)
            }
            if case .failed(let message)? = download?.state {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: EA app (Madeira's EA support: no EA app is installed)

    private var filteredEAGames: [EAOwnedGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let games = eaLibrary.owned.filter(\.downloadable)
        guard !query.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var eaContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("EA app")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(tr("Sign in on EA's own page to see your EA games and install them without the EA app. iDeck keeps only the sign-in token, in this device's Keychain."))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(tr("Connect EA")) { isEASignInPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelColor)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func eaCard(_ game: EAOwnedGame) -> some View {
        let installed = eaLibrary.installed[game.id]
        let download = eaLibrary.downloads[game.id]
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    GOGArtworkView(urls: [game.cover].compactMap { $0 }, fallbackColor: secondaryColor, fill: true)
                        .libraryCoverFrame()
                        .contentShape(Rectangle())
                        .onTapGesture { selectedEAGame = game }
                        .blur(radius: installed == nil && download == nil ? Self.uninstalledCoverBlur : 0)
                    if installed == nil && download == nil {
                        downloadCoverButton { eaLibrary.install(game.id) }
                    }
                }
                .libraryCoverFrame()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                Button { selectedEAGame = game } label: { cardTitle(game.title) }
                    .buttonStyle(.plain)
            }
            if case .failed(let message)? = download?.state {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Licence, registry, the EA app's environment and local service, then Wine.
    private func launchEAGame(_ game: EAInstalledGame) {
        let executable = EALibrary.drive.appendingPathComponent(game.programPath)
        var profile = windowsLibrary.profile(for: "ea:\(game.offerID)", title: game.title)
        // StikDebug opens on the tap, while EA's licence is being fetched.
        coordinator.prewarmJITForLaunch()
        Task { @MainActor in
            do {
                try await eaLibrary.prepareLaunch(offerID: game.offerID, nvidiaGPU: profile.reportNVIDIA, avx: profile.avxEnabled)
                profile.arguments = [profile.arguments, game.arguments].filter { !$0.isEmpty }.joined(separator: " ")
                coordinator.launchWindowsProgram(at: executable, profile: profile, detectInstaller: false)
            } catch {
                installMessage = error.localizedDescription
                isShowingInstallResult = true
            }
        }
    }

    private func launchEpicGame(_ game: EpicInstalledGame) {
        let executable = game.launchURL(in: EpicLibrary.drive)
        let savedProfile = windowsLibrary.profile(for: "epic:\(game.appName)", title: game.title)
        // StikDebug opens on the tap, while Epic's launch token is being fetched
        // (that request took seconds and JIT activation only started after it).
        coordinator.prewarmJITForLaunch()
        Task { @MainActor in
            do {
                let epicArguments = try await epicLibrary.launchArguments(appName: game.appName)
                var profile = savedProfile
                profile.arguments = [profile.arguments, epicArguments].filter { !$0.isEmpty }.joined(separator: " ")
                coordinator.launchWindowsProgram(at: executable, profile: profile, detectInstaller: false)
            } catch {
                installMessage = error.localizedDescription
                isShowingInstallResult = true
            }
        }
    }

    private func resolvePrefixPath() {
        coordinator.prefixHost.mountEnvironment { mountedPath in
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
                // Keep the first Wine prefix initialization architecture-only.
                // Steam client components are installed from the explicit Madeira Dock step.
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
    // JIT is requested by SystemCoordinator at the exact launch boundary.
    // Do not block GOG/Epic here: launchWindowsExecutable automatically opens
    // StikDebug and resumes only after live debugger/JIT readiness is proven.

    private func launchGOGGame(_ game: GOGInstalledGame) {
        var profile = windowsLibrary.profile(for: "gog:\(game.gameID)", title: game.name)
        if profile.arguments.isEmpty { profile.arguments = game.arguments }
        // GOG Galaxy's game services (sign-in, achievements, stats) for this game,
        // with a token minted for its own client, before Wine starts.
        Task { @MainActor in
            await GOGGalaxy.shared.prepare(gameID: game.gameID, drive: EpicLibrary.drive)
            // What GOG Galaxy does after an install, done before the start (as Madeira):
            // the install script's registry values, then the redistributables' installers.
            let drive = EpicLibrary.drive
            let folder = GOGLibraryModel.installFolder(containing: game.executable.deletingLastPathComponent())
            GOGLaunchServices.applyInstallScripts(folder: folder, drive: drive)
            if let batch = GOGLaunchServices.setupBatch(gameID: game.gameID, folder: folder, executable: game.executable,
                                                        arguments: profile.arguments, drive: drive),
               let shell = MadeiraDock.stageCommandShell() {
                var setup = profile
                setup.arguments = "/c \"\(batch)\""
                coordinator.launchWindowsExecutable(at: shell, profile: setup)
                return
            }
            coordinator.launchWindowsProgram(at: game.executable, profile: profile, detectInstaller: false)
        }
    }

    /// Installs a GOG game the way GOG Galaxy does: the game's Galaxy build,
    /// straight from GOG's content system. No offline installer.
    private func downloadGOGInstaller(_ game: GOGGame) {
        guard let prefixPath else { return }
        gogLibrary.install(game, prefixPath: prefixPath) { _ in
            windowsLibrary.refresh(prefixPath: prefixPath)
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
        coordinator.prefixHost.mountEnvironment { mountedPath in
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
    /// Fill the frame and crop (EA's 9:16 pack art in a 2:3 card); fit otherwise.
    var fill = false
    @State private var index = 0

    var body: some View {
        Group {
            if index < urls.count {
                ArtworkImage(url: urls[index], failed: { index += 1 }) { image in
                    if fill {
                        image.resizable().scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                    } else {
                        image.resizable().scaledToFit()
                    }
                } placeholder: {
                    fallbackColor.overlay(ProgressView().tint(.gray))
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
                    // Starts the program; without JIT, StikDebug opens first.
                    Button {
                        library.save(profile)
                        dismiss()
                        coordinator.launchWindowsProgram(at: executableURL, profile: profile)
                    } label: {
                        Label(tr("Launch"), systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
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
    var launch: (SteamAppInfo) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var profile: WindowsGameProfile
    @State private var errorMessage: String?
    @State private var showError = false

    init(game: SteamAppInfo, prefixPath: URL?, library: WindowsLibraryStore,
         steamLibrary: SteamOwnedGamesModel, coordinator: SystemCoordinator,
         launch: @escaping (SteamAppInfo) -> Void = { _ in }) {
        self.launch = launch
        self.game = game
        self.prefixPath = prefixPath
        self.library = library
        self.steamLibrary = steamLibrary
        self.coordinator = coordinator
        let initial = library.profile(for: "steam:\(game.appID)", title: game.name)
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
                        // Starts the game; without JIT, StikDebug opens first.
                        Button {
                            dismiss()
                            launch(game)
                        } label: {
                            Label(tr("Launch"), systemImage: "play.fill")
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
                    SteamAchievementsCard(appID: game.appID)
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
        let measured = installed ? (steamLibrary.installedSizes[game.appID] ?? 0) : 0
        let reported = game.displaySizeForWindows(installedBytes: measured)
        guard reported.bytes > 0 else { return nil }
        let text = ByteCountFormatter.string(fromByteCount: Int64(clamping: reported.bytes), countStyle: .file)
        return reported.isRequirement ? tr("Minimum required space: %@", text) : text
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
            if let progress, progress.phase == .downloading,
               let eta = DownloadETA.seconds(done: progress.doneBytes,
                                             total: progress.totalBytes,
                                             bytesPerSecond: progress.bytesPerSecond),
               let remaining = DownloadETA.label(eta) {
                Label(tr("Time left") + ": " + remaining, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                DetailPickerRow(title: tr("JIT pool"), selection: Binding(
                                    get: { profile.jitPoolMiB == 0 ? tr("Automatic") : "\(profile.jitPoolMiB) MB" },
                                    set: { value in profile.jitPoolMiB = Int(value.split(separator: " ").first ?? "") ?? 0 }),
                                choices: WindowsGameProfile.jitPoolChoices.map { $0 == 0 ? tr("Automatic") : "\($0) MB" },
                                icon: "memorychip", iconColor: .orange)
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
    let etaSeconds: Int?
    /// Bytes on the device so far while installing ("1.2 GB / 4 GB"), as a Steam game's page shows.
    let installedText: String?
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
         installed: Bool, progress: Double?, etaSeconds: Int? = nil, installedText: String? = nil,
         paused: Bool = false, sizeText: String?, errorText: String?,
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
        self.etaSeconds = etaSeconds
        self.installedText = installedText
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
        let initial = library.profile(for: profileID, title: title)
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
                if let etaSeconds, let eta = DownloadETA.label(etaSeconds) {
                    Label(tr("Time left") + ": " + eta, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let installedText {
                    Text(tr("Installed: %@", installedText))
                        .font(.caption2)
                        .foregroundColor(.green)
                }
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
            // Starts the game; without JIT, StikDebug opens first.
            Button {
                dismiss()
                onLaunch()
            } label: {
                Label(tr("Launch"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
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

/// "1.2 GB / 4 GB": what a download has put on the device so far, of its total.
private func installedBytesText(done: UInt64, total: UInt64) -> String? {
    guard total > 0, done > 0 else { return nil }
    let format = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
    return format(min(done, total)) + " / " + format(total)
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
            etaSeconds: gog.downloadETASeconds[game.id],
            installedText: gog.downloadedBytes[game.id].flatMap { installedBytesText(done: $0.done, total: $0.total) },
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

/// EA game details use the same game page as GOG and Epic.
private struct EAGameDetailsSheet: View {
    let game: EAOwnedGame
    @ObservedObject var ea: EALibrary
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    let launch: (EAInstalledGame) -> Void

    private var sizeText: String? {
        if let installed = ea.installed[game.id], installed.installBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: installed.installBytes, countStyle: .file)
        }
        if case .known(_, let bytes)? = ea.sizes[game.id], bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return tr("Size unavailable")
    }

    var body: some View {
        let installed = ea.installed[game.id]
        let download = ea.downloads[game.id]
        let failed: String? = {
            if case .failed(let message) = download?.state { return message }
            return nil
        }()
        let paused: Bool = {
            if case .paused = download?.state { return true }
            return false
        }()
        let eta: Int? = {
            guard let download, download.progress.phase == .downloading else { return nil }
            return DownloadETA.seconds(done: download.progress.doneBytes,
                                       total: download.progress.totalBytes,
                                       bytesPerSecond: download.progress.bytesPerSecond)
        }()
        StoreGameDetailsView(
            title: game.title, store: .ea, profileID: "ea:\(game.id)",
            covers: [game.cover].compactMap { $0 },
            banners: [game.wide].compactMap { $0 },
            installed: installed != nil && download == nil,
            progress: (download != nil && failed == nil) ? download?.progress.fraction : nil,
            etaSeconds: eta,
            installedText: download.flatMap { $0.progress.phase == .downloading
                ? installedBytesText(done: $0.progress.doneBytes, total: $0.progress.totalBytes) : nil },
            paused: paused, sizeText: sizeText, errorText: failed,
            canInstall: game.downloadable,
            onLaunch: { if let installed { launch(installed) } },
            onInstall: { ea.install(game.id) },
            onPause: { ea.pause(game.id) },
            onStop: { ea.cancel(game.id) },
            onUninstall: download == nil ? { ea.uninstall(game.id); return true } : nil,
            library: library, coordinator: coordinator
        ) {
            if let installed {
                DetailCard(title: "EA app") {
                    DetailValueRow(title: tr("Version"), value: installed.version,
                                   icon: "number", iconColor: .gray)
                    if ea.updateAvailable(game.id) {
                        DetailButtonRow(title: tr("Update"), systemImage: "arrow.down.circle") {
                            ea.install(game.id)
                        }
                    }
                    DetailButtonRow(title: tr("Repair"), systemImage: "wrench.and.screwdriver",
                                    showsDivider: false) {
                        ea.repair(game.id)
                    }
                }
            }
        }
        .task(id: game.id) {
            await ea.loadSize(game.id)
            await ea.checkForUpdate(game.id)
        }
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
        let eta: Int? = {
            guard let download, download.progress.phase == .downloading else { return nil }
            return DownloadETA.seconds(done: download.progress.doneBytes,
                                       total: download.progress.totalBytes,
                                       bytesPerSecond: download.progress.bytesPerSecond)
        }()
        StoreGameDetailsView(
            title: title, store: .epic, profileID: "epic:\(appName)",
            covers: [epic.game(appName)?.cover].compactMap { $0 },
            banners: [epic.game(appName)?.wide].compactMap { $0 },
            installed: installed != nil && download == nil,
            progress: (download != nil && failed == nil) ? download?.progress.fraction : nil,
            etaSeconds: eta,
            installedText: download.flatMap { $0.progress.phase == .downloading
                ? installedBytesText(done: $0.progress.doneBytes, total: $0.progress.totalBytes) : nil },
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
                if let list = epic.dlcs[appName], !list.isEmpty {
                    DetailCard(title: tr("DLCs")) { epicDLCList(list) }
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

    /// The game's DLC, as the Steam page lists them: install, progress, uninstall.
    private func epicDLCList(_ list: [EpicOwnedDLC]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { dlc in
                let download = epic.downloads[dlc.appName]
                let failed: String? = { if case .failed(let message) = download?.state { return message }; return nil }()
                HStack(spacing: 12) {
                    AsyncImage(url: dlc.image) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color(white: 0.2) }
                    .frame(width: 92, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dlc.title)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        if let download, failed == nil {
                            ProgressView(value: download.progress.fraction).tint(.blue)
                            Text(tr("Installing %d%%", Int((download.progress.fraction * 100).rounded())))
                                .font(.caption2)
                                .foregroundColor(.white)
                        } else if let failed {
                            Text(failed).font(.caption2).foregroundColor(.red).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 6)
                    if download != nil && failed == nil {
                        Button(role: .destructive) { epic.cancel(dlc.appName) } label: {
                            Label(tr("Cancel"), systemImage: "xmark.circle.fill").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    } else if epic.installedDLC[dlc.appName] != nil {
                        Button(role: .destructive) { epic.uninstallDLC(dlc.appName) } label: {
                            Label(tr("Uninstall"), systemImage: "trash").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(epic.sessionRunning)
                    } else {
                        Button { epic.installDLC(dlc.appName) } label: {
                            Text(tr("Install")).font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(epic.downloads[appName] != nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if dlc.id != list.last?.id {
                    Divider().background(Color.white.opacity(0.08)).padding(.leading, 120)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// An EA app game, installed or installing (its offer id).
    case ea(String)
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
            + eaShelfIDs.map { .ea($0) }
            + windowsLibrary.executableURLs.map { .exe($0.path) }
    }

    /// EA games installed or installing, by title.
    private var eaShelfIDs: [String] {
        Set(eaLibrary.installed.keys).union(eaLibrary.downloads.keys)
            .sorted { eaTitle($0).localizedCaseInsensitiveCompare(eaTitle($1)) == .orderedAscending }
    }

    private func eaTitle(_ id: String) -> String {
        eaLibrary.game(id)?.title ?? eaLibrary.installed[id]?.title ?? "EA app"
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
                    ForEach([GameStore.steam, .gog, .epic, .ea], id: \.self) { store in
                        shelfTile(.store(store))
                    }
                    if !shelfGames.isEmpty {
                        // Over the selected game's blurred artwork the dark line colour read
                        // as a scratch: a soft light rule shows on any background.
                        Capsule().fill(Color.white.opacity(0.28)).frame(width: 2, height: shelfTileHeight * 0.5)
                            .padding(.top, shelfTileHeight * 0.25)
                    }
                    ForEach(shelfGames, id: \.self) { item in
                        shelfTile(item)
                    }
                }
                .padding(.vertical, 10)
                // Room for the selected tile's 1.08 scale and border, which the
                // scroll view's edge would otherwise cut on the first tile.
                .padding(.horizontal, 14)
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
            // A game's tile opens its details, where Launch starts it.
            if case .store = item {} else { openSettings(item) }
        } label: {
            // Artwork only: no caption under a store or a game, no download bar on it.
            shelfArtwork(item)
                .frame(width: shelfTileWidth, height: shelfTileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? textColor : lineColor, lineWidth: selected ? 2 : 1))
                .scaleEffect(selected ? 1.08 : 1)
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
                    .renderingMode(store == .steam || store == .ea ? .original : .template)
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
        case .ea(let id):
            GOGArtworkView(urls: [eaLibrary.game(id)?.cover].compactMap { $0 }, fallbackColor: panelColor, fill: true)
        case .exe(let path):
            WindowsExecutableArtworkView(executableURL: URL(fileURLWithPath: path), library: windowsLibrary, fallbackColor: panelColor)
        }
    }

    private func storeAsset(_ store: GameStore) -> String {
        switch store {
        case .steam: return "StoreBadgeSteam"
        case .gog: return "StoreBadgeGOG"
        case .epic: return "StoreBadgeEpic"
        case .ea: return "StoreBadgeEA"
        }
    }

    private func shelfTitle(_ item: ShelfItem) -> String {
        switch item {
        case .store(.steam): return "Steam"
        case .store(.gog): return "GOG"
        case .store(.epic): return "Epic Games"
        case .store(.ea): return "EA app"
        case .steam(let id): return steamLibrary.games.first { $0.appID == id }?.name ?? "Steam"
        case .gog(let id): return gogLibrary.installed[id]?.name ?? "GOG"
        case .gogInstalling(let id): return gogLibrary.games.first { $0.id == id }?.title ?? "GOG"
        case .epic(let app): return epicLibrary.installed[app]?.title ?? "Epic"
        case .epicInstalling(let app): return epicLibrary.game(app)?.title ?? "Epic"
        case .ea(let id): return eaTitle(id)
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
            case .ea:
                if eaLibrary.signedIn {
                    storeGrid(loading: eaLibrary.refreshing, error: eaLibrary.error,
                              count: eaLibrary.owned.count, entries: filteredEAGames.map { .ea($0) })
                } else {
                    eaContent
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
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(sorted) { entry in
                    switch entry {
                    case .steam(let game): gameCard(game)
                    case .gog(let game): gogCard(game)
                    case .epic(let game): epicCard(game)
                    case .ea(let game): eaCard(game)
                    }
                }
            }
        }
    }

    /// The selected game's name. Its cover is the shelf backdrop
    /// (`shelfBackdrop`); its tile opens the details, where Launch starts it.
    private func gamePage(_ item: ShelfItem) -> some View {
        Text(shelfTitle(item))
            .font(.system(size: isCompact ? 22 : 28, weight: .semibold))
            .foregroundColor(textColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Game backdrop: the selected game's cover fills the screen behind the
    /// store and game tiles, blurred and darkened. It does nothing when touched.
    @ViewBuilder
    var shelfBackdrop: some View {
        if case .store = currentShelf {
            EmptyView()
        } else {
            gameHero(currentShelf)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 24)
                .overlay(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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

    private func openSettings(_ item: ShelfItem) {
        switch item {
        case .steam(let id):
            if let game = steamLibrary.games.first(where: { $0.appID == id }) { selectedSteamGame = SelectedSteamGame(game: game) }
        case .gog(let id), .gogInstalling(let id):
            selectedGOGGame = gogLibrary.games.first { $0.id == id }
        case .epic(let app), .epicInstalling(let app):
            selectedEpicGame = SelectedEpicGame(id: app)
        case .ea(let id):
            selectedEAGame = eaLibrary.game(id)
        case .exe(let path):
            selectedExecutable = SelectedLibraryURL(url: URL(fileURLWithPath: path))
        default:
            break
        }
    }
}


// MARK: First-run setup

private struct IDeckFirstRunSetupView: View {
    @ObservedObject var coordinator: SystemCoordinator
    let onFinish: () -> Void

    @AppStorage(SystemCoordinator.jitMethodKey) private var jitMethod = "stikdebug"
    @ObservedObject private var wineMono = WineMonoModel.shared
    @AppStorage("firstRunSetup.step.v2") private var step = 0
    @State private var installing = false
    @State private var installerStatus = ""
    @State private var refresh = 0
    @State private var pairingImporterPresented = false

    private enum Step: Int, CaseIterable {
        case visualCpp, wineMono, dock, jit, summary
        var title: String {
            switch self {
            case .visualCpp: return "Visual C++"
            case .wineMono: return "Wine Mono"
            case .dock: return "Madeira Dock"
            case .jit: return "JIT"
            case .summary: return "Summary"
            }
        }
        var icon: String {
            switch self {
            case .visualCpp: return "shippingbox.fill"
            case .wineMono: return "gearshape.2.fill"
            case .dock: return "dock.rectangle"
            case .jit: return "bolt.fill"
            case .summary: return "checkmark.seal.fill"
            }
        }
        var tint: Color {
            switch self {
            case .visualCpp: return .blue
            case .wineMono: return .purple
            case .dock: return .teal
            case .jit: return .orange
            case .summary: return .green
            }
        }
    }

    // Palette: one neutral background, one card surface, one hairline.
    private let background = Color(red: 0.043, green: 0.047, blue: 0.063)
    private let surface = Color(red: 0.094, green: 0.102, blue: 0.129)
    private let hairline = Color.white.opacity(0.08)

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var prefixReady: Bool { PrefixInstaller.isPrefixInstalled(at: MadeiraDock.prefix) }
    /// The Windows runtime itself is part of the IPA; the Wine environment (prefix)
    /// is prepared by the Visual C++ step before the runtimes go into it.
    private var vcReady: Bool {
        VisualCRuntimeBootstrap.installed(in: MadeiraDock.prefix, documents: documents)
            && VisualCRuntimeLegacy.installed(documents: documents)
    }
    private var steamDLLsReady: Bool {
        guard let folder = SteamDLLRepair.sourceFolder else { return false }
        let root = MadeiraDock.prefix.appendingPathComponent("drive_c")
            .appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true)
        return (SteamDLLRepair.mediaLibraries + [SteamDLLRepair.sdlLibrary]).allSatisfy {
            SteamDLLRepair.validX64DLL(folder.appendingPathComponent($0))
                || SteamDLLRepair.validX64DLL(root.appendingPathComponent($0))
        }
    }

    private func done(_ item: Step) -> Bool {
        switch item {
        case .visualCpp: return prefixReady && vcReady
        case .wineMono: return wineMono.installed
        case .dock: return MadeiraDock.clientInstalled
        case .jit: return jitMethod != "builtIn" || coordinator.hasPairingFile
        case .summary: return false
        }
    }

    var body: some View {
        let current = Step(rawValue: step) ?? .summary
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header(current)
                        stepper(current)
                        VStack(alignment: .leading, spacing: 20) {
                            switch current {
                            case .visualCpp: visualCppStep
                            case .wineMono: wineMonoStep
                            case .dock: dockStep
                            case .jit: jitStep
                            case .summary: completeStep
                            }
                        }
                        .id(refresh)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(hairline, lineWidth: 1))
                        footer(current)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarHidden(true)
        }
        .fileImporter(isPresented: $pairingImporterPresented,
                      allowedContentTypes: [.propertyList, .xml, .json, .data]) { result in
            if case .success(let url) = result { coordinator.importPairingFile(at: url) }
        }
        .onAppear {
            coordinator.refreshJITStatus()
            coordinator.refreshPairingFileState()
            wineMono.refresh()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Layout

    private func header(_ current: Step) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to iDeck")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text("Step \(current.rawValue + 1) of \(Step.allCases.count) · \(current.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Numbered steps joined by a line; finished ones show a check. Tappable when idle.
    private func stepper(_ current: Step) -> some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                let isCurrent = item == current
                let finished = done(item) && !isCurrent
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { step = item.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? item.tint : (finished ? Color.green.opacity(0.18) : surface))
                                .overlay(Circle().stroke(isCurrent ? Color.clear : hairline, lineWidth: 1))
                                .frame(width: 32, height: 32)
                            if finished {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                            } else {
                                Text("\(item.rawValue + 1)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(isCurrent ? .white : .secondary)
                            }
                        }
                        Text(item.title)
                            .font(.caption2.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(installing || wineMono.busy)
                if item != Step.allCases.last {
                    Rectangle()
                        .fill(done(item) ? Color.green.opacity(0.5) : hairline)
                        .frame(height: 1)
                        .frame(maxWidth: 28)
                        .offset(y: -10)
                }
            }
        }
    }

    private func footer(_ current: Step) -> some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { step -= 1 } } label: {
                    Label("Back", systemImage: "chevron.left").frame(minWidth: 90)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            Spacer()
            if current != .summary {
                Button { withAnimation(.easeInOut(duration: 0.2)) { step += 1 } } label: {
                    HStack(spacing: 6) { Text("Continue"); Image(systemName: "chevron.right") }.frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing || wineMono.busy
                          || (current == .visualCpp && !(prefixReady && vcReady))
                          || (current == .wineMono && !wineMono.installed))
            } else {
                Button { step = 0; onFinish() } label: { Text("Start using iDeck").frame(minWidth: 160) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .controlSize(.large)
        .disabled(installing)
    }

    /// The top of a step: tinted icon tile, title and one line of explanation.
    private func stepHeader(_ item: Step, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 40, height: 40)
                .background(item.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Component rows inside a step, drawn as a grouped list.
    private func componentList<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        VStack(spacing: 0) { rows() }
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hairline, lineWidth: 1))
    }

    private func statusRow(_ title: String, _ ready: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(ready ? Color.green : Color.secondary)
            Text(title).font(.body).foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(detail ?? (ready ? "Installed" : "Not installed"))
                .font(.caption.weight(.medium))
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((ready ? Color.green : Color.white).opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func primaryButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var progressNote: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(installerStatus.isEmpty ? coordinator.windowsStatus : installerStatus)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Visual C++

    private var visualCppStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.visualCpp, "Prepares the Windows environment and installs Microsoft Visual C++ 2005–2022, which most games and programs need.")
            componentList {
                statusRow("Windows environment (x64 + x86)", prefixReady)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Microsoft Visual C++ 2005–2022", vcReady)
            }
            primaryButton(prefixReady && vcReady ? "Installed" : (installing ? "Installing…" : "Install"),
                          systemImage: prefixReady && vcReady ? "checkmark" : "arrow.down.circle",
                          disabled: installing || (prefixReady && vcReady) || !MadeiraRuntime.available) {
                installVisualCpp()
            }
            if installing { progressNote }
            else if !installerStatus.isEmpty { note(installerStatus) }
            if !MadeiraRuntime.available {
                note("This IPA does not include the Windows runtime. Install a native iDeck IPA.", warning: true)
            }
            note("Downloaded from Microsoft.")
        }
    }

    // MARK: - Wine Mono

    private var wineMonoStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.wineMono, "Installs Wine Mono, the .NET Framework that programs and launchers built with .NET need.")
            componentList {
                statusRow("Wine Mono \(WineMonoPin.version)", wineMono.installed, detail: wineMono.busy ? wineMono.status : nil)
            }
            primaryButton(wineMono.installed ? "Installed" : (wineMono.busy ? "Installing…" : "Install"),
                          systemImage: wineMono.installed ? "checkmark" : "arrow.down.circle",
                          disabled: wineMono.installed || wineMono.busy) {
                wineMono.install()
            }
            if wineMono.busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(wineMono.status).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = wineMono.error { note(error, warning: true) }
            note("Downloaded from WineHQ, about \(Int((Double(WineMonoPin.tarBytes) / 1_000_000).rounded())) MB.")
        }
    }

    /// Prepares the Wine environment, then installs every Visual C++ runtime; each
    /// part is skipped when present.
    private func installVisualCpp() {
        guard !installing else { return }
        installing = true
        let docs = documents
        Task { @MainActor in
            defer { installing = false; refresh += 1 }
            // An IPA built with a split runtime downloads Wine's Windows files first.
            for package in MadeiraRuntime.packages where !MadeiraRuntime.installed(package.id) {
                do {
                    try await MadeiraRuntime.install(package.id) { message, fraction in
                        Task { @MainActor in installerStatus = "\(message) \(Int(fraction * 100))%" }
                    }
                } catch {
                    installerStatus = error.localizedDescription
                    return
                }
            }
            if !prefixReady {
                installerStatus = "Preparing the Windows environment…"
                coordinator.openMadeiraWorkspace()
                for _ in 0..<600 where !prefixReady {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard prefixReady else {
                    installerStatus = "The Windows environment could not be prepared: \(coordinator.windowsStatus)"
                    return
                }
            }
            refresh += 1
            // 2015-2022 x64 (vcruntime140 & co.).
            if !VisualCRuntimeBootstrap.installed(in: MadeiraDock.prefix, documents: docs) {
                installerStatus = "Downloading Microsoft Visual C++ 2015-2022 (x64)…"
                let downloaded: Result<URL, Error> = await withCheckedContinuation { done in
                    VisualCRuntimeBootstrap.download(in: MadeiraDock.prefix) { done.resume(returning: $0) }
                }
                guard case .success(let installer) = downloaded else {
                    if case .failure(let error) = downloaded { installerStatus = error.localizedDescription }
                    return
                }
                installerStatus = "Installing Microsoft Visual C++ 2015-2022 (x64)…"
                let installed: Result<Void, Error> = await withCheckedContinuation { done in
                    VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: docs) { done.resume(returning: $0) }
                }
                if case .failure(let error) = installed { installerStatus = error.localizedDescription; return }
            }
            // 2005-2013 (x86/x64) and 2015-2022 x86.
            if !VisualCRuntimeLegacy.installed(documents: docs) {
                let failures = await VisualCRuntimeLegacy.installAll(documents: docs) { name in
                    Task { @MainActor in installerStatus = "Installing Microsoft Visual C++ \(name)…" }
                }
                if !failures.isEmpty {
                    installerStatus = "Some runtimes failed: " + failures.joined(separator: "; ") + ". Tap Install to retry."
                    return
                }
            }
            installerStatus = vcReady ? "Visual C++ installed." : "Some components are missing. Tap Install to retry."
        }
    }

    // MARK: - Madeira Dock

    private var dockStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.dock, "Runs Valve's official Steam client, so Steam games start with their licence and DRM intact.")
            componentList {
                statusRow("Steam client", MadeiraDock.clientInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Steam DLLs", steamDLLsReady)
            }
            primaryButton(MadeiraDock.clientInstalled ? "Repair Madeira Dock" : "Install Madeira Dock",
                          systemImage: MadeiraDock.clientInstalled ? "wrench.and.screwdriver" : "arrow.down.circle",
                          disabled: !MadeiraDock.bundled || !prefixReady) {
                coordinator.installMadeiraDock()
            }
            if let progress = coordinator.steamComponentsProgress {
                note(progress, warning: progress.contains("failed") || progress.contains("missing"))
            }
            if !prefixReady {
                note("Install Visual C++ first: it prepares the Windows environment.", warning: true)
            }
            note("Optional: only needed for Steam games.")
        }
    }

    // MARK: - JIT

    private var jitStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.jit, "Choose how iDeck turns JIT on each time a game starts.")
            Picker("JIT method", selection: $jitMethod) {
                Text("StikDebug").tag("stikdebug")
                Text("Built-in").tag("builtIn")
            }
            .pickerStyle(.segmented)
            if jitMethod == "builtIn" {
                componentList {
                    statusRow("Pairing file", coordinator.hasPairingFile, detail: coordinator.hasPairingFile ? "Imported" : "Missing")
                }
                Button(coordinator.hasPairingFile ? "Replace pairing file" : "Import pairing file") {
                    pairingImporterPresented = true
                }
                .buttonStyle(.bordered)
                note("Built-in turns JIT on from inside iDeck with this device's pairing file.")
            } else {
                note("iDeck opens StikDebug when a game starts, and StikDebug turns JIT on for it.")
            }
        }
    }

    // MARK: - Summary

    private var completeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.summary, "Everything iDeck needs. Unfinished items can be completed later from Settings.")
            componentList {
                statusRow("Visual C++", prefixReady && vcReady)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Wine Mono", wineMono.installed)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Madeira Dock", MadeiraDock.clientInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("JIT method", true, detail: jitMethod == "builtIn" ? "Built-in" : "StikDebug")
            }
        }
    }
}

private extension View {
    /// A library cover as Madeira draws it: the card's full width at 2:3.
    func libraryCoverFrame() -> some View {
        frame(maxWidth: .infinity).aspectRatio(2.0 / 3.0, contentMode: .fit)
    }
}
