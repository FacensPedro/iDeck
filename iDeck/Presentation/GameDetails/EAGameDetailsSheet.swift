// EAGameDetailsSheet.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

/// EA game details use the same game page as GOG and Epic.
struct EAGameDetailsSheet: View {
    let game: EAOwnedGame
    @ObservedObject var ea: EALibrary
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    let launch: (EAInstalledGame) -> Void

    var sizeText: String? {
        if let installed = ea.installed[game.id], installed.installBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: installed.installBytes, countStyle: .file)
        }
        if case .known(_, let bytes)? = ea.sizes[game.id], bytes > 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        // Still asking EA: nothing yet, not "unavailable".
        if case .unavailable? = ea.sizes[game.id] { return tr("Size unavailable") }
        return nil
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
                ? installedBytesText(done: $0.progress.doneBytes, total: $0.progress.totalBytes, showZero: true) : nil },
            paused: paused, waiting: download?.state == .queued, sizeText: sizeText, errorText: failed,
            canInstall: game.downloadable,
            onLaunch: { if let installed { launch(installed) } },
            onInstall: { StoreProviders.of(.ea).install(game.id, prefix: nil) },
            onPause: { StoreProviders.of(.ea).pause(game.id) },
            onStop: { StoreProviders.of(.ea).cancel(game.id) },
            onUninstall: (download == nil || paused) ? { StoreProviders.of(.ea).uninstall(game.id, prefix: nil) } : nil,
            library: library, coordinator: coordinator
        ) {
            if let installed {
                DetailCard(title: "EA app") {
                    DetailValueRow(title: tr("Version"), value: installed.version,
                                   icon: "number", iconColor: .gray)
                    if ea.updateAvailable(game.id) {
                        DetailButtonRow(title: tr("Update"), systemImage: "arrow.down.circle") {
                            StoreProviders.of(.ea).install(game.id, prefix: nil)
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
