// GOGGameDetailsSheet.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

/// GOG game page.
struct GOGGameDetailsSheet: View {
    let game: GOGGame
    let prefixPath: URL?
    @ObservedObject var gog: GOGLibraryModel
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    let launch: (GOGInstalledGame) -> Void
    let install: (GOGGame) -> Void

    var sizeText: String? {
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
                let gogStore = StoreProviders.of(.gog)
                if gogStore.downloadState(String(game.id)) == .paused { gogStore.resume(String(game.id), prefix: prefixPath) }
                else { install(game) }
            },
            onPause: { StoreProviders.of(.gog).pause(String(game.id)) },
            onStop: { StoreProviders.of(.gog).cancel(String(game.id)) },
            onUninstall: prefixPath.map { prefix in { StoreProviders.of(.gog).uninstall(String(game.id), prefix: prefix) } },
            library: library, coordinator: coordinator
        ) { EmptyView() }
        .task(id: game.id) { await gog.loadSize(for: game) }
    }
}
