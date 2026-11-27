// Library: Steam cards, launch and install.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension WindowsWorkspaceView {
    func gameCard(_ game: SteamAppInfo) -> some View {
        let installed = steamLibrary.installedApps.contains(game.appID)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Button { selectedSteamGame = SelectedSteamGame(game: game) } label: {
                        SteamGameArtworkView(game: game)
                            .libraryCoverFrame()
                            .blur(radius: !installed && AntiCheatPolicy.isBlocked(title: game.name, steamAppID: game.appID) ? Self.uninstalledCoverBlur : 0)
                    }
                    .buttonStyle(.plain)
                    if !installed && AntiCheatPolicy.isBlocked(title: game.name, steamAppID: game.appID) {
                        antiCheatCoverBadge
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

    func launchSteamGame(_ game: SteamAppInfo) {
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

    func install(_ game: SteamAppInfo) {
        coordinator.prefixHost.mountEnvironment { mountedPath in
            guard let mountedPath else {
                coordinator.setWindowsStatus("Container initialization failed")
                return
            }
            let root = URL(fileURLWithPath: mountedPath, isDirectory: true)
            Task { @MainActor in
                prefixPath = root
                StoreProviders.of(.steam).install(String(game.appID), prefix: root)
            }
        }
    }
}
