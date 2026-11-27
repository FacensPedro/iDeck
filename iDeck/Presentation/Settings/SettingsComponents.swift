// SettingsComponents.swift
// Split from SettingsView.swift (iDeck 3.0 architecture).

import SwiftUI

/// A settings row: a coloured symbol tile, a title and an optional value.
struct SettingsRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String? = nil
    /// An asset image used in place of the SF Symbol.
    var asset: String? = nil
    /// Draws the asset in its own colors filling the tile (Steam's round logo).
    var assetKeepsColors = false
    /// Draws a one-color asset in the text color with no tile behind it (GOG).
    var assetPlain = false

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(assetPlain ? Color.primary : Color.white)
                .frame(width: 28, height: 28)
                .background(assetKeepsColors || assetPlain ? Color.clear : color,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var iconView: some View {
        if let asset, assetKeepsColors {
            Image(asset).renderingMode(.original).resizable().scaledToFit()
        } else if let asset {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .padding(assetPlain ? 2 : 5)
        } else {
            Image(systemName: icon)
        }
    }
}

struct SettingsStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Install (downloads the official installer, then runs it) for a store's own Windows
/// client, with the download's progress; once installed, only its state.
struct StoreClientButton: View {
    let client: SystemCoordinator.StoreClient
    @ObservedObject var coordinator: SystemCoordinator

    let openStore: (SystemCoordinator.StoreClient) -> Void
    @State private var installed = false

    var body: some View {
        Group {
            if let progress = coordinator.storeClientDownload {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progress).foregroundStyle(.secondary)
                }
            } else {
                if installed {
                    // The launcher is not opened from iDeck: its games are on its store page.
                    LabeledContent(client.rawValue, value: tr("Installed"))
                } else if coordinator.storeSetupInBackground {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(tr("Installing %@...", client.rawValue)).foregroundStyle(.secondary)
                    }
                } else {
                    Button(tr("Install")) { openStore(client) }
                    if let error = coordinator.storeClientError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
        }
        .task(id: coordinator.windowsStatus) {
            let result = await Task.detached(priority: .utility) { [client] in client.installedURL != nil }.value
            if !Task.isCancelled { installed = result }
        }
    }
}

/// A store page's card while the account is not connected: the launcher is installed
/// by the initial setup, so the card asks for the sign-in.
struct StoreClientCard: View {
    let client: SystemCoordinator.StoreClient
    @ObservedObject var coordinator: SystemCoordinator

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compactUbisoftText: Bool {
        client == .ubisoft && UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(client.rawValue)
                .font(compactUbisoftText ? .subheadline.weight(.semibold) : .headline)
                .foregroundColor(.white)
            Text(tr("Sign in in Settings › Stores & launchers › %@.", client.rawValue))
                .font(compactUbisoftText ? .footnote : .subheadline)
                .foregroundColor(.gray)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
