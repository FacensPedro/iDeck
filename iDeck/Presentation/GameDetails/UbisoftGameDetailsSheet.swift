// UbisoftGameDetailsSheet.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

/// Ubisoft Connect game page, as EA's: install, pause, stop, the download's error, and
/// Play once installed (the game's own program; the launcher is not opened).
struct UbisoftGameDetailsSheet: View {
    let gameID: String
    /// The game as the card showed it, while the library list is being replaced.
    let fallback: UbisoftGame
    @ObservedObject var ubisoft: UbisoftLibrary
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator

    var body: some View {
        let game = ubisoft.game(gameID) ?? fallback
        // Download state through the StoreProvider (3.1).
        let download = StoreProviders.of(.ubisoft).downloadStatus(gameID)
        let failed = download?.failure
        let paused = download?.isPaused ?? false
        let installed = game.executable != nil
        let sizeText: String = {
            guard let total = download?.totalBytes, total > 0 else { return tr(installed ? "Installed" : "Size unavailable") }
            return tr("Download: %@", ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))
        }()
        StoreGameDetailsView(
            title: game.title, store: .ubisoft, profileID: "ubisoft:\(gameID)",
            covers: game.coverURLs.filter { $0.lastPathComponent != "header.jpg" },
            banners: game.coverURLs.filter { $0.lastPathComponent == "header.jpg" },
            installed: installed && download == nil,
            progress: download?.progress,
            installedText: download.flatMap { installedBytesText(done: $0.doneBytes, total: $0.totalBytes) },
            paused: paused, sizeText: sizeText, errorText: failed,
            canInstall: !installed && !AntiCheatPolicy.isBlocked(title: game.title),
            onLaunch: {
                guard let executable = game.executable else { return }
                let profile = library.profile(for: "ubisoft:\(gameID)", title: game.title)
                coordinator.launchWindowsProgram(at: executable, profile: profile, detectInstaller: false)
            },
            onInstall: { StoreProviders.of(.ubisoft).install(game.id, prefix: nil) },
            onPause: { StoreProviders.of(.ubisoft).pause(game.id) },
            onStop: { StoreProviders.of(.ubisoft).cancel(game.id) },
            onUninstall: nil,
            library: library, coordinator: coordinator
        ) {
            if let download, case .active = download.state, download.totalBytes == 0, let step = download.step {
                Text(step).font(.caption).foregroundColor(.gray)
            }
        }
    }
}
