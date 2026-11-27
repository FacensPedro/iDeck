// Library: GOG list, cards, launch and installer download.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension WindowsWorkspaceView {
    @ViewBuilder
    var gogContent: some View {
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

    func gogCard(_ game: GOGGame) -> some View {
        let installed = gogLibrary.installed[game.id]
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Button { selectedGOGGame = game } label: {
                        GOGArtworkView(urls: game.artworkCandidates, fallbackColor: secondaryColor, fill: true)
                            .libraryCoverFrame()
                            .blur(radius: installed == nil && AntiCheatPolicy.isBlocked(title: game.title) ? Self.uninstalledCoverBlur : 0)
                    }
                    .buttonStyle(.plain)
                    if installed == nil && AntiCheatPolicy.isBlocked(title: game.title) {
                        antiCheatCoverBadge
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

    func launchGOGGame(_ game: GOGInstalledGame) {
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
    func downloadGOGInstaller(_ game: GOGGame) {
        guard let prefixPath else { return }
        gogLibrary.install(game, prefixPath: prefixPath) { _ in
            windowsLibrary.refresh(prefixPath: prefixPath)
        }
    }
}
