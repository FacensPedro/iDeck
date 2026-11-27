// Library: EA app list, cards and launch.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension WindowsWorkspaceView {
    var filteredEAGames: [EAOwnedGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let games = eaLibrary.owned.filter(\.downloadable)
        guard !query.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var eaContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("EA app")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(tr("Sign in to EA to see your games. iDeck keeps the sign-in token in this device's Keychain."))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(tr("Connect EA")) { isEASignInPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelColor)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(lineColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func eaCard(_ game: EAOwnedGame) -> some View {
        let installed = eaLibrary.installed[game.id]
        let download = eaLibrary.downloads[game.id]
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    GOGArtworkView(urls: [game.cover].compactMap { $0 }, fallbackColor: secondaryColor, fill: true)
                        .libraryCoverFrame()
                        .contentShape(Rectangle())
                        .onTapGesture { selectedEAGame = game }
                        .blur(radius: installed == nil && AntiCheatPolicy.isBlocked(title: game.title) ? Self.uninstalledCoverBlur : 0)
                    if installed == nil && AntiCheatPolicy.isBlocked(title: game.title) {
                        antiCheatCoverBadge
                    }
                }
                .libraryCoverFrame()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipped()
                Button { selectedEAGame = game } label: { cardTitle(game.title) }
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
}
