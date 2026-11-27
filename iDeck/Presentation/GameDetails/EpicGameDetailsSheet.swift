// EpicGameDetailsSheet.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

/// Epic game page.
struct EpicGameDetailsSheet: View {
    let appName: String
    @ObservedObject var epic: EpicLibrary
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    let launch: (EpicInstalledGame) -> Void

    var title: String { epic.game(appName)?.title ?? epic.installed[appName]?.title ?? "Epic Games" }

    var sizeText: String? {
        let installedBytes = epic.installed[appName]?.installBytes
        guard let bytes = installedBytes ?? epic.manifestSizes[appName], bytes > 0 else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return installedBytes == nil ? tr("Download: %@", formatted) : tr("Installed: %@", formatted)
    }

    var body: some View {
        let installed = epic.installed[appName]
        let download = epic.downloads[appName]
        let failed: String? = { if case .failed(let message) = download?.state { return message }; return nil }()
        let paused: Bool = { if case .paused = download?.state { return true }; return false }()
        let eta: Int? = {
            guard let download, download.progress.phase == .downloading else { return nil }
            return DownloadETA.seconds(done: download.progress.doneBytes,
                                       total: download.progress.totalBytes,
                                       bytesPerSecond: download.progress.bytesPerSecond)
        }()
        StoreGameDetailsView(
            title: title, store: .epic, profileID: "epic:\(appName)",
            covers: [epic.game(appName)?.cover].compactMap { $0 },
            banners: [epic.game(appName)?.wide].compactMap { $0 },
            installed: installed != nil && download == nil,
            progress: (download != nil && failed == nil) ? download?.progress.fraction : nil,
            etaSeconds: eta,
            installedText: download.flatMap { $0.progress.phase == .downloading
                ? installedBytesText(done: $0.progress.doneBytes, total: $0.progress.totalBytes) : nil },
            paused: paused, waiting: download?.state == .queued, sizeText: sizeText, errorText: failed,
            canInstall: true,
            onLaunch: { if let installed { launch(installed) } },
            onInstall: { epic.install(appName) },
            onPause: { epic.pause(appName) },
            onStop: { epic.cancel(appName) },
            // Always shown: a save check running in the background (it starts when this page
            // opens) hid the button. While a game runs or a sync writes saves, the removal
            // waits for it instead.
            onUninstall: {
                guard !epic.sessionRunning else { return false }
                epic.uninstall(appName)
                return epic.installed[appName] == nil
            },
            library: library, coordinator: coordinator
        ) {
            if installed != nil {
                DetailCard(title: "Epic Games") {
                    DetailValueRow(title: tr("Version"), value: installed?.buildVersion ?? "",
                                   icon: "number", iconColor: .gray)
                    if epic.updateAvailable(appName) {
                        DetailButtonRow(title: tr("Update"), systemImage: "arrow.down.circle") { epic.install(appName) }
                    }
                    DetailButtonRow(title: tr("Repair"), systemImage: "wrench.and.screwdriver", showsDivider: false) {
                        epic.repair(appName)
                    }
                }
                if let list = epic.dlcs[appName], !list.isEmpty {
                    DetailCard(title: tr("DLCs")) { epicDLCList(list) }
                }
                if let packs = epic.optionalPacks[appName], !packs.isEmpty {
                    DetailCard(title: tr("Optional content")) { epicPackList(packs) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    EpicCloudSection(appName: appName)
                }
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: appName) {
            await epic.loadSize(appName)
            await epic.loadOptionalPacks(appName)
        }
    }

    /// Optional content inside the game's own build, installed and removed one by one
    /// like a DLC: Epic ships some DLC, textures and voice languages this way.
    private func epicPackList(_ packs: [EpicOptionalPack]) -> some View {
        VStack(spacing: 0) {
            ForEach(packs) { pack in
                let installedPack = epic.packInstalled(appName, tag: pack.tag)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pack.tag).font(.subheadline).foregroundColor(.white).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file))
                            .font(.caption2).foregroundColor(.gray)
                    }
                    Spacer(minLength: 6)
                    if installedPack {
                        Button(role: .destructive) { epic.uninstallPack(appName, tag: pack.tag) } label: {
                            Label(tr("Uninstall"), systemImage: "trash").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { epic.installPack(appName, tag: pack.tag) } label: {
                            Text(tr("Install")).font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(epic.downloads[appName] != nil || epic.sessionRunning)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if pack.id != packs.last?.id {
                    Divider().background(Color.white.opacity(0.08)).padding(.leading, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The game's DLC, as the Steam page lists them: install, progress, uninstall.
    private func epicDLCList(_ list: [EpicOwnedDLC]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { dlc in
                let download = epic.downloads[dlc.appName]
                let failed: String? = { if case .failed(let message) = download?.state { return message }; return nil }()
                HStack(spacing: 12) {
                    AsyncImage(url: dlc.image) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color(white: 0.2) }
                    .frame(width: 92, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dlc.title)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        if let download, failed == nil {
                            ProgressView(value: download.progress.fraction).tint(.blue)
                            Text(tr("Installing %d%%", Int((download.progress.fraction * 100).rounded())))
                                .font(.caption2)
                                .foregroundColor(.white)
                        } else if let failed {
                            Text(failed).font(.caption2).foregroundColor(.red).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 6)
                    if download != nil && failed == nil {
                        Button(role: .destructive) { epic.cancel(dlc.appName) } label: {
                            Label(tr("Cancel"), systemImage: "xmark.circle.fill").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    } else if epic.installedDLC[dlc.appName] != nil {
                        Button(role: .destructive) { epic.uninstallDLC(dlc.appName) } label: {
                            Label(tr("Uninstall"), systemImage: "trash").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(epic.sessionRunning)
                    } else {
                        Button { epic.installDLC(dlc.appName) } label: {
                            Text(tr("Install")).font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(epic.downloads[appName] != nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if dlc.id != list.last?.id {
                    Divider().background(Color.white.opacity(0.08)).padding(.leading, 120)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
