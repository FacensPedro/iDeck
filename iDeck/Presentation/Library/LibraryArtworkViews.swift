// LibraryArtworkViews.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

struct SteamGameArtworkView: View {
    let game: SteamAppInfo
    var shelf = false

    var candidates: [URL] {
        var urls: [URL] = []
        func append(_ url: URL?) {
            if let url, !urls.contains(url) { urls.append(url) }
        }
        if let asset = game.libraryCapsule,
           asset.utf8.count <= 256,
           !asset.isEmpty,
           !asset.hasPrefix("/"),
           !asset.contains(".."),
           asset.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) {
            append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.appID)/\(asset)"))
        }
        append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)/library_600x900.jpg"))
        if let parentID = game.parentID {
            append(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(parentID)/library_600x900.jpg"))
        }
        if let header = game.headerImage,
           header.utf8.count <= 256,
           !header.isEmpty,
           !header.hasPrefix("/"),
           !header.contains(".."),
           header.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }) {
            append(URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.appID)/\(header)"))
        }
        return urls
    }

    var body: some View {
        Group {
            if game.appID == 407530 {
                Color.clear.overlay {
                    Image("ARKSurvivalOfTheFittest").resizable().scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                GOGArtworkView(urls: candidates, fallbackColor: Color.white.opacity(0.06), fill: shelf)
                    .id(game.appID)
            }
        }
        .accessibilityLabel(game.name)
    }
}

/// A GOG or Epic game's banner, drawn exactly like SteamGameBannerView:
/// the whole image fitted in a 220-point rounded panel.
struct GameDetailsBannerFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct StoreBannerView: View {
    let urls: [URL]
    @State var imageIndex = 0

    var body: some View {
        Group {
            if imageIndex < urls.count {
                ArtworkImage(url: urls[imageIndex], failed: { imageIndex += 1 }) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ZStack {
                        Color.white.opacity(0.06)
                        ProgressView().tint(.gray)
                    }
                }
                .id(imageIndex)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .modifier(GameDetailsBannerFrame())
    }
}

struct SteamGameBannerView: View {
    let game: SteamAppInfo
    @State var imageIndex = 0

    var candidates: [URL] {
        var urls: [URL] = []
        for asset in [game.libraryHero, game.headerImage] {
            guard let asset, !asset.isEmpty, asset.utf8.count <= 256,
                  !asset.hasPrefix("/"), !asset.contains(".."),
                  asset.unicodeScalars.allSatisfy({
                      $0.isASCII && (CharacterSet.alphanumerics.contains($0) ||
                      "._-/".unicodeScalars.contains($0))
                  }) else { continue }
            if let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.appID)/\(asset)") {
                urls.append(url)
            }
        }
        if let fallback = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(game.appID)/header.jpg") {
            urls.append(fallback)
        }
        return urls
    }

    var body: some View {
        AsyncImage(url: imageIndex < candidates.count ? candidates[imageIndex] : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else if phase.error != nil {
                Color.white.opacity(0.06)
                    .onAppear { if imageIndex + 1 < candidates.count { imageIndex += 1 } }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView().tint(.gray)
                }
            }
        }
        .modifier(GameDetailsBannerFrame())
        .task(id: game.appID) { imageIndex = 0 }
    }
}

/// A GOG cover: tries each candidate URL in turn, then a plain tile.
struct GOGArtworkView: View {
    let urls: [URL]
    let fallbackColor: Color
    /// Fill the frame and crop (EA's 9:16 pack art in a 2:3 card); fit otherwise.
    var fill = false
    /// Shown instead of the controller icon when no address gave a picture.
    var fallbackTitle: String? = nil
    @State var index = 0

    var body: some View {
        Group {
            if index < urls.count {
                ArtworkImage(url: urls[index], failed: { index += 1 }) { image in
                    if fill {
                        image.resizable().scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                    } else {
                        image.resizable().scaledToFit()
                    }
                } placeholder: {
                    fallbackColor.overlay(ProgressView().tint(.gray))
                }
                .id(index)
            } else if let fallbackTitle {
                fallbackColor.overlay(
                    Text(fallbackTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(10))
            } else {
                fallbackColor.overlay(
                    Image(systemName: "gamecontroller")
                        .font(.largeTitle)
                        .foregroundColor(.gray))
            }
        }
        // Take the size the card gives (the same 2:3 frame as a Steam cover)
        // and crop to it, as SteamGameArtworkView does: a filled image is
        // otherwise drawn larger than its frame and spills out of it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WindowsExecutableArtworkView: View {
    let executableURL: URL
    @ObservedObject var library: WindowsLibraryStore
    let fallbackColor: Color

    var body: some View {
        let profile = library.profile(forExecutable: executableURL)
        Group {
            if let url = library.artworkURL(for: profile), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.13, green: 0.18, blue: 0.24), fallbackColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "app.dashed")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityLabel(profile.title)
    }
}

/// A DLC's own cover: its store header first (DLC rarely have a library capsule).
struct SteamDLCArtworkView: View {
    let appID: UInt32
    @State var index = 0

    var candidates: [URL] {
        ["header.jpg", "capsule_231x87.jpg", "capsule_616x353.jpg", "library_600x900.jpg"].compactMap {
            URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\($0)")
        }
    }

    var body: some View {
        AsyncImage(url: index < candidates.count ? candidates[index] : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if phase.error != nil {
                Color.white.opacity(0.08).onAppear { if index < candidates.count { index += 1 } }
            } else {
                Color.white.opacity(0.08)
            }
        }
    }
}

/// One tile of the top shelf: a store, or a game that is installed or installing.
enum ShelfItem: Hashable {
    static func storeKey(_ store: GameStore) -> String {
        switch store { case .steam: "steam"; case .gog: "gog"; case .epic: "epic"; case .ea: "ea"; case .ubisoft: "ubisoft" }
    }
    /// The store tab saved in "library.lastStore" (Steam when none).
    static var savedStore: GameStore {
        switch UserDefaults.standard.string(forKey: "library.lastStore") {
        case "gog": .gog
        case "epic": .epic
        case "ea": .ea
        default: .steam
        }
    }

    case store(GameStore)
    case steam(UInt32)
    case gog(Int)
    case gogInstalling(Int)
    case epic(String)
    case epicInstalling(String)
    /// An EA app game, installed or installing (its offer id).
    case ea(String)
    case exe(String)
}

/// The download symbol struck through: a game that needs Easy Anti-Cheat.
struct AntiCheatBlockedSymbol: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Image(systemName: "arrow.down.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.gray)
            Capsule()
                .fill(Color.red)
                .frame(width: size * 1.15, height: max(3, size / 10))
                .rotationEffect(.degrees(-45))
        }
        .frame(width: size, height: size)
    }
}

/// The game page's install button for a game that needs Easy Anti-Cheat: grey,
/// disabled, saying why it cannot be installed.
struct AntiCheatBlockedButton: View {
    var body: some View {
        VStack(spacing: 8) {
            Button {} label: {
                Label {
                    Text(tr("Cannot install"))
                } icon: {
                    AntiCheatBlockedSymbol(size: 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)
            .disabled(true)
            Text(tr(AntiCheatPolicy.message))
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
    }
}
