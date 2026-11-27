// Library: Ubisoft Connect cards and download badge.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension WindowsWorkspaceView {
    var filteredUbisoftGames: [UbisoftGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ubisoftLibrary.games }
        return ubisoftLibrary.games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// An installed Ubisoft game starts its own program directly; one the account owns
    /// but has not installed says where to install it.
    func ubisoftCard(_ game: UbisoftGame) -> some View {
        // Opens the game's page, as for the other stores: install, pause, stop and
        // errors are there.
        let open = { selectedUbisoftGame = game }
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if !game.coverURLs.isEmpty {
                    // No text over Ubisoft covers: the title is shown under the card.
                    GOGArtworkView(urls: game.coverURLs, fallbackColor: secondaryColor, fill: true)
                        .id(game.coverURLs)
                } else if let executable = game.executable {
                    WindowsExecutableArtworkView(executableURL: executable, library: windowsLibrary, fallbackColor: secondaryColor)
                } else {
                    secondaryColor
                    Image(systemName: "gamecontroller")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                }
            }
            .libraryCoverFrame()
            .blur(radius: game.executable == nil && AntiCheatPolicy.isBlocked(title: game.title) ? Self.uninstalledCoverBlur : 0)
            .overlay(alignment: .bottom) {
                if let download = StoreProviders.of(.ubisoft).downloadStatus(game.id) { ubisoftDownloadBadge(download) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .contextMenu {
                if StoreProviders.of(.ubisoft).downloadStatus(game.id) != nil {
                    Button(role: .destructive) { StoreProviders.of(.ubisoft).cancel(game.id) } label: {
                        Label(tr("Stop download"), systemImage: "xmark.circle")
                    }
                }
            }
            Button(action: open) { cardTitle(game.title) }
                .buttonStyle(.plain)
            if let message = StoreProviders.of(.ubisoft).downloadStatus(game.id)?.failure {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A Ubisoft download's state over its cover: the step or the percentage, and a bar.
    private func ubisoftDownloadBadge(_ download: StoreDownloadStatus) -> some View {
        let text: String
        let fraction = download.progress ?? 0
        switch download.state {
        case .queued: text = tr("Waiting…")
        case .active: text = download.totalBytes > 0 ? "\(Int(fraction * 100))%" : (download.step ?? "")
        case .paused: text = download.totalBytes > 0 ? "\(Int(fraction * 100))%" : ""   // no "Paused" text
        case .failed: text = tr("Download failed")
        }
        return VStack(spacing: 4) {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            ProgressView(value: fraction)
                .tint(.white)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.6))
    }
}
