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
            coordinator.autoEnableBuiltInJIT()
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
                await StoreProviders.of(.steam).refresh()
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

struct WindowsWorkspaceView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @ObservedObject var steamLibrary: SteamOwnedGamesModel

    @State private var pendingStore: SystemCoordinator.StoreClient?
    @State var isSettingsPresented = false
    @State var searchText = ""
    /// The selected tile of the console-style shelf (a store or a game).
    /// The selected store or game. Starts on the store chosen last (2.13.3): the
    /// library view is rebuilt when iDeck comes back from StikDebug, and an EA game's
    /// launch returned to the Steam tab.
    @State var shelf: ShelfItem = .store(ShelfItem.savedStore)
    /// The last store tab chosen, kept across view rebuilds and app restarts.
    @AppStorage("library.lastStore") var lastStore = "steam"
    @State var prefixPath: URL?
    @StateObject var windowsLibrary = WindowsLibraryStore()
    @State var isExecutablePickerPresented = false
    @State var isExecutableMenuPresented = false
    @State var selectedExecutable: SelectedLibraryURL?
    @State var selectedSteamGame: SelectedSteamGame?
    @State var installMessage: String?
    @State var isShowingInstallResult = false
    @State var pendingSteamCompatibilityLaunch: (game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL)?
    @State var steamCompatibilityMessage = ""
    @State var showingSteamCompatibilityWarning = false
    @ObservedObject var gogLibrary = GOGLibraryModel.shared
    @State var isGOGSignInPresented = false
    @AppStorage("library.gogOwnedCollapsed") var gogOwnedCollapsed = false
    @ObservedObject var epicLibrary = EpicLibrary.shared
    @State var isEpicSignInPresented = false
    @State var isEASignInPresented = false
    @ObservedObject var eaLibrary = EALibrary.shared
    @ObservedObject var ubisoftLibrary = UbisoftLibrary.shared
    @State var ubisoftClientInstalled = false
    /// Follows a sign-in or sign-out in Settings (UbisoftLibrary publishes it).
    var ubisoftSignedIn: Bool { ubisoftLibrary.signedIn }
    @State var selectedEpicGame: SelectedEpicGame?
    @State var selectedEAGame: EAOwnedGame?
    @State var selectedUbisoftGame: UbisoftGame?
    @State var selectedGOGGame: GOGGame?
    @AppStorage("library.epicOwnedCollapsed") var epicOwnedCollapsed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Palette: panel #0b0b0d, card #111114, line #1f1f24.
    let panelColor = Color(red: 0x0b/255, green: 0x0b/255, blue: 0x0d/255)
    let secondaryColor = Color(red: 0x11/255, green: 0x11/255, blue: 0x14/255)
    let lineColor = Color(red: 0x1f/255, green: 0x1f/255, blue: 0x24/255)
    private let accentColor = Color(red: 0x3b/255, green: 0x82/255, blue: 0xf6/255)
    let textColor = Color(red: 0xf4/255, green: 0xf4/255, blue: 0xf5/255)
    private let faintColor = Color(red: 0x71/255, green: 0x71/255, blue: 0x7a/255)

    var filteredSteamGames: [SteamAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return steamLibrary.games }
        return steamLibrary.games.filter {
            $0.name.localizedCaseInsensitiveContains(query) || String($0.appID).contains(query)
        }
    }

    var installedSteamGames: [SteamAppInfo] {
        // Through the StoreProvider (3.0.1): installed, or downloading now.
        let steamStore = StoreProviders.of(.steam)
        let installed = steamStore.installedIDs
        return steamLibrary.games.filter { game in
            let id = String(game.appID)
            return installed.contains(id) || steamStore.downloadState(id)?.isRunning == true
        }
    }

    var filteredGOGGames: [GOGGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return gogLibrary.games }
        return gogLibrary.games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var filteredEpicGames: [EpicOwnedGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return epicLibrary.owned }
        return epicLibrary.owned.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var installedEpicGames: [EpicInstalledGame] {
        epicLibrary.installed.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var installedGOGGames: [GOGInstalledGame] {
        gogLibrary.installed.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// GOG and Epic games being installed: listed under Installed games with
    /// their progress, as Steam games are while they download.
    var installingGOGGames: [GOGGame] {
        let gogStore = StoreProviders.of(.gog)
        let installed = gogStore.installedIDs
        return gogLibrary.games.filter { gogStore.hasDownload(String($0.id)) && !installed.contains(String($0.id)) }
    }

    var installingEpicGames: [EpicOwnedGame] {
        let epicStore = StoreProviders.of(.epic)
        let installed = epicStore.installedIDs
        return epicLibrary.owned.filter { epicStore.downloadStatus($0.appName) != nil && !installed.contains($0.appName) }
    }

    var isCompact: Bool { horizontalSizeClass == .compact }

    /// Blur of the cover of a game that cannot be installed (Easy Anti-Cheat).
    static let uninstalledCoverBlur: CGFloat = 1.5

    /// Madeira's library lattice: 20 pt between columns, 18 pt between rows.
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isCompact ? 110 : 154, maximum: 220), spacing: 20)]
    }

    func cardTitle(_ title: String) -> some View {
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

    /// In place of the Install button on a game that needs Easy Anti-Cheat: only the
    /// struck-through symbol, in the middle of the cover, not tappable.
    var antiCheatCoverBadge: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(.white.opacity(0.75))
            .frame(width: 46, height: 46)
            .overlay(
                Capsule()
                    .fill(Color(red: 1.0, green: 0.36, blue: 0.34))
                    .frame(width: 34, height: 3.5)
                    .rotationEffect(.degrees(-45))
            )
            .background(.ultraThinMaterial, in: Circle())
            .background(Circle().fill(Color.black.opacity(0.5)))
            .overlay(Circle().strokeBorder(Color(red: 1.0, green: 0.42, blue: 0.4).opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)
            .accessibilityLabel(tr(AntiCheatPolicy.shortMessage))
    }

    /// A collapsible "owned games" header (store, count, chevron).
    func ownedHeader(_ title: String, collapsed: Binding<Bool>) -> some View {
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
        .sheet(isPresented: $isSettingsPresented, onDismiss: {
            if let client = pendingStore {
                pendingStore = nil
                coordinator.openStoreClient(client)
            }
        }) {
            SettingsView(coordinator: coordinator, openStore: { client in
                pendingStore = client
                isSettingsPresented = false
            })
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
        .sheet(item: $selectedUbisoftGame) { game in
            UbisoftGameDetailsSheet(gameID: game.id, fallback: game, ubisoft: ubisoftLibrary, library: windowsLibrary,
                                    coordinator: coordinator)
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
        .onChange(of: coordinator.windowsStatus) { _, status in
            guard let prefixPath else { return }
            let ended = status == "Windows Ready" || status.hasPrefix("Execution Error") || status.hasPrefix("Cannot launch")
            Task { @MainActor in
                // Wine can still be closing when the session's end is shown: wait for it
                // (up to 20 s), so the installer leaves the list as soon as Wine stops.
                var waited = 0
                while ended && ideck_wineprocess_running() && waited < 40 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 1
                }
                guard !ideck_wineprocess_running() else { return }
                gogLibrary.refreshInstalled(prefixPath: prefixPath)
                windowsLibrary.refresh(prefixPath: prefixPath)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: EA app (Madeira's EA support: no EA app is installed)

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
                StoreProviders.of(.steam).refreshInstalled(prefix: root)
                gogLibrary.refreshInstalled(prefixPath: root)
                // Keep the first Wine prefix initialization architecture-only.
                // Steam client components are installed from the explicit Madeira Dock step.
                }
        }
    }

    /// Looks again for installed games of every store and Windows programs.
    func reloadInstalledGames() {
        resolvePrefixPath()
        guard let prefixPath else { return }
        StoreProviders.of(.steam).refreshInstalled(prefix: prefixPath)
        gogLibrary.refreshInstalled(prefixPath: prefixPath)
        epicLibrary.reloadInstalled()
        windowsLibrary.refresh(prefixPath: prefixPath)
    }

    /// JIT must be on before any Windows program starts.
    // JIT is requested by SystemCoordinator at the exact launch boundary.
    // Do not block GOG/Epic here: launchWindowsExecutable automatically opens
    // StikDebug and resumes only after live debugger/JIT readiness is proven.

}

// MARK: First-run setup

