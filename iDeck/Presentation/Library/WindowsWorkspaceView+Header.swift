// Library: top bar, Steam sign-in button and the all-stores list.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension WindowsWorkspaceView {
    var steamConnectButton: some View {
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

    var topBar: some View {
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
    enum MixedLibraryEntry: Identifiable {
        case steam(SteamAppInfo)
        case gog(GOGGame)
        case epic(EpicOwnedGame)
        case ea(EAOwnedGame)
        case ubisoft(UbisoftGame)

        var id: String {
            switch self {
            case .steam(let game): return "steam:\(game.appID)"
            case .gog(let game): return "gog:\(game.id)"
            case .epic(let game): return "epic:\(game.id)"
            case .ea(let game): return "ea:\(game.id)"
            case .ubisoft(let game): return "ubisoft:\(game.id)"
            }
        }

        var title: String {
            switch self {
            case .steam(let game): return game.name
            case .gog(let game): return game.title
            case .epic(let game): return game.title
            case .ea(let game): return game.title
            case .ubisoft(let game): return game.title
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

    var mixedLibraryLoading: Bool {
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
    func refreshAllLibraries() {
        reloadInstalledGames()
        if coordinator.isSteamConnected { Task { await steamLibrary.refresh(force: true) } }
        if gogLibrary.isSignedIn { Task { await gogLibrary.refresh() } }
        if epicLibrary.signedIn { Task { await epicLibrary.refreshLibrary() } }
        if eaLibrary.signedIn { Task { await eaLibrary.refreshLibrary() } }
        if ubisoftClientInstalled || ubisoftSignedIn { ubisoftLibrary.refresh() }
    }
}
