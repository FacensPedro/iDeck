// Library: Epic Games list, cards and launch.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension WindowsWorkspaceView {
    @ViewBuilder
    var epicContent: some View {
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

    func epicCard(_ game: EpicOwnedGame) -> some View {
        let installed = epicLibrary.installed[game.appName]
        let download = epicLibrary.downloads[game.appName]
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Button { selectedEpicGame = SelectedEpicGame(id: game.appName) } label: {
                        GOGArtworkView(urls: [game.cover].compactMap { $0 }, fallbackColor: secondaryColor, fill: true)
                            .libraryCoverFrame()
                            .blur(radius: installed == nil && AntiCheatPolicy.isBlocked(title: game.title, epicAppName: game.appName) ? Self.uninstalledCoverBlur : 0)
                    }
                    .buttonStyle(.plain)
                    if installed == nil && AntiCheatPolicy.isBlocked(title: game.title, epicAppName: game.appName) {
                        antiCheatCoverBadge
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

    func launchEpicGame(_ game: EpicInstalledGame) {
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
}
