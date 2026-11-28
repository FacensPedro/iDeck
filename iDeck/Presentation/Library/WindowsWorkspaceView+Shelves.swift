// WindowsWorkspaceView+Shelves.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

// MARK: - Console-style home (PS-like shelf)

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
        StoreProviders.of(.ea).installedOrDownloadingIDs
            .sorted { eaTitle($0).localizedCaseInsensitiveCompare(eaTitle($1)) == .orderedAscending }
    }

    private func eaTitle(_ id: String) -> String {
        eaLibrary.game(id)?.title ?? eaLibrary.installed[id]?.title ?? "EA app"
    }

    /// The selected tile, or the Steam store when it no longer exists.
    var currentShelf: ShelfItem {
        if case .store = shelf { return shelf }
        return shelfGames.contains(shelf) ? shelf : .store(ShelfItem.savedStore)
    }

    var consoleShelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: isCompact ? 8 : 14) {
                    // No Ubisoft Connect tab: its download service refuses iDeck's connection.
                    ForEach([GameStore.steam, .gog, .epic, .ea], id: \.self) { store in
                        shelfTile(.store(store))
                    }
                    ForEach(shelfGames, id: \.self) { item in
                        shelfTile(item)
                    }
                }
                .padding(.vertical, 10)
                // Room for the selected tile's 1.08 scale and border, which the
                // scroll view's edge would otherwise cut on the first tile.
                .padding(.horizontal, isCompact ? 10 : 14)
            }
            .onChange(of: shelf) { _, item in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(item, anchor: .center) }
                if case .store(let store) = item { lastStore = ShelfItem.storeKey(store) }
            }
        }
    }

    /// iPhone in portrait: 56 pt tiles, 8 pt apart, so five fit across a 6.1" (390 pt)
    /// or smaller (375 pt) screen: 10 + 5 × 56 + 4 × 8 + 10 = 332 pt.
    private var shelfTileWidth: CGFloat { isCompact ? 56 : 78 }
    private var shelfTileHeight: CGFloat { isCompact ? 76 : 104 }

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
                    .renderingMode(store == .steam || store == .ea || store == .ubisoft ? .original : .template)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(textColor)
                    .padding(shelfTileWidth * 0.22)
            }
        case .steam(let id):
            if let game = steamLibrary.games.first(where: { $0.appID == id }) {
                SteamGameArtworkView(game: game, shelf: true)
            } else { panelColor }
        case .gog(let id), .gogInstalling(let id):
            GOGArtworkView(urls: gogLibrary.games.first { $0.id == id }?.artworkCandidates ?? [], fallbackColor: panelColor)
        case .epic(let app), .epicInstalling(let app):
            GOGArtworkView(urls: [epicLibrary.game(app)?.cover].compactMap { $0 }, fallbackColor: panelColor, fill: true)
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
        case .ubisoft: return "StoreBadgeUbisoft"
        case .ea: return "StoreBadgeEA"
        }
    }

    private func shelfTitle(_ item: ShelfItem) -> String {
        switch item {
        case .store(.steam): return "Steam"
        case .store(.gog): return "GOG"
        case .store(.epic): return "Epic Games"
        case .store(.ea): return "EA app"
        case .store(.ubisoft): return "Ubisoft Connect"
        case .steam(let id): return steamLibrary.games.first { $0.appID == id }?.name ?? "Steam"
        case .gog(let id): return gogLibrary.installed[id]?.name ?? "GOG"
        case .gogInstalling(let id): return gogLibrary.games.first { $0.id == id }?.title ?? "GOG"
        case .epic(let app): return epicLibrary.installed[app]?.title ?? "Epic"
        case .epicInstalling(let app): return epicLibrary.game(app)?.title ?? "Epic"
        case .ea(let id): return eaTitle(id)
        case .exe(let path): return windowsLibrary.displayName(for: URL(fileURLWithPath: path))
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
            if (store != .ubisoft || ubisoftClientInstalled || ubisoftSignedIn) && (store != .ea || eaLibrary.signedIn) {
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
            case .ubisoft:
                Group {
                    if ubisoftClientInstalled || ubisoftSignedIn {
                        storeGrid(loading: ubisoftLibrary.refreshing, error: ubisoftLibrary.error,
                                  count: ubisoftLibrary.games.count, entries: filteredUbisoftGames.map { .ubisoft($0) })
                    } else {
                        // The launcher is installed by the initial setup: what is missing is the sign-in.
                        StoreClientCard(client: .ubisoft, coordinator: coordinator)
                    }
                }
                .task(id: coordinator.windowsStatus) {
                    let installed = await Task.detached(priority: .utility) {
                        SystemCoordinator.StoreClient.ubisoft.installedURL != nil
                    }.value
                    guard !Task.isCancelled else { return }
                    ubisoftClientInstalled = installed
                    if installed || UbisoftSavedSession.load() != nil { ubisoftLibrary.refresh() }
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
                    case .ubisoft(let game): ubisoftCard(game)
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
