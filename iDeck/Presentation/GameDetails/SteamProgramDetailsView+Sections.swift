// Steam game page: size, Steam Cloud saves, download status and DLCs.
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

extension SteamProgramDetailsView {
    /// Size on disk when installed; otherwise what the account's own
    /// edition takes once installed (or, failing that, its download size).
    var installedSizeText: String? {
        let measured = installed ? (steamLibrary.installedSizes[game.appID] ?? 0) : 0
        let reported = game.displaySizeForWindows(installedBytes: measured, ownedDLC: steamLibrary.ownedDepotIDs)
        guard reported.bytes > 0 else { return nil }
        let text = ByteCountFormatter.string(fromByteCount: Int64(clamping: reported.bytes), countStyle: .file)
        return reported.isRequirement ? tr("Minimum required space: %@", text) : text
    }

    var steamCloudControls: some View {
        let syncing = steamLibrary.cloudSyncing.contains(game.appID)
        return VStack(spacing: 0) {
            DetailRow(title: tr("Auto Save"), icon: "icloud.fill", iconColor: .blue) {
                if syncing { ProgressView() }
                Toggle(tr("Auto Save"), isOn: $autoSaveEnabled).labelsHidden().tint(.green)
            }
            if steamLibrary.cloudConflicts.contains(game.appID) {
                DetailRow(title: tr("Conflicting saves: choose which copy to keep. The replaced copy will be backed up."),
                          icon: "exclamationmark.triangle.fill", iconColor: .orange) { EmptyView() }
                DetailButtonRow(title: tr("Use Steam Cloud saves"), systemImage: "icloud.and.arrow.down") {
                    guard let prefixPath else { return }
                    Task { await steamLibrary.resolveCloud(appID: game.appID, prefixPath: prefixPath, preferCloud: true) }
                }
                .disabled(prefixPath == nil || syncing)
                DetailButtonRow(title: tr("Use local saves"), systemImage: "internaldrive") {
                    guard let prefixPath else { return }
                    Task { await steamLibrary.resolveCloud(appID: game.appID, prefixPath: prefixPath, preferCloud: false) }
                }
                .disabled(prefixPath == nil || syncing)
            }
            DetailButtonRow(title: tr("Sync saves now"), systemImage: "arrow.triangle.2.circlepath.icloud",
                            showsDivider: false) {
                guard let prefixPath else { return }
                Task { await steamLibrary.syncCloud(appID: game.appID, prefixPath: prefixPath) }
            }
            .disabled(prefixPath == nil || syncing)
        }
    }

    /// The download's state comes through the StoreProvider (3.0.1).
    var downloadStatus: some View {
        let status = StoreProviders.of(.steam).downloadStatus(String(game.appID))
        let stopping = status?.stopping ?? false
        let fraction = status?.progress ?? 0
        let verify = status?.verifyFraction ?? 0
        return VStack(spacing: 10) {
            ProgressView(value: status?.phase == .verifying ? verify : fraction)
            Text(status?.waiting == true ? tr("Waiting") :
                 status == nil || status?.phase == .preparing ? tr("Preparing download...") :
                 status?.phase == .verifying ? tr("Checking existing files %d%%", Int((verify * 100).rounded())) :
                 status?.phase == .finishing ? tr("Finishing installation...") :
                 tr("Installing %d%%", Int((fraction * 100).rounded())))
                .font(.caption)
                .foregroundColor(.white)
            if let remaining = DownloadETA.label(status?.etaSeconds) {
                Label(tr("Time left") + ": " + remaining, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let written = status?.writtenBytes, written > 0 {
                Text(tr("Installed: %@", ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: written), countStyle: .file)))
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            if status?.cancellable == true {
                // Pause keeps the files; Stop uninstalls the game.
                HStack(spacing: 10) {
                    Button {
                        StoreProviders.of(.steam).pause(String(game.appID))
                    } label: {
                        Label(tr("Pause"), systemImage: "pause.fill")
                            .downloadControlLabel()
                    }
                    .disabled(stopping)
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    Button(role: .destructive) {
                        StoreProviders.of(.steam).cancel(String(game.appID))
                    } label: {
                        Label(stopping ? tr("Stopping...") : tr("Stop"), systemImage: "stop.fill")
                            .downloadControlLabel()
                    }
                    .disabled(stopping)
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
        }
    }

    /// The game's DLC, through the StoreProvider (3.0.1): list, size, progress,
    /// install, cancel and uninstall.
    var dlcList: some View {
        let steamStore = StoreProviders.of(.steam)
        let gameID = String(game.appID)
        let dlcs = steamStore.dlcs(of: gameID)
        return VStack(spacing: 0) {
            if dlcs.isEmpty {
                DetailRow(title: tr("No DLC found for this game"), showsDivider: false) { EmptyView() }
            }
            ForEach(dlcs, id: \.id) { dlc in
                let status = steamStore.dlcDownloadStatus(dlc.id, of: gameID)
                HStack(spacing: 12) {
                    SteamDLCArtworkView(appID: UInt32(dlc.id) ?? 0)
                        .frame(width: 92, height: 43)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dlc.title)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        if let bytes = dlc.sizeBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        if let status {
                            let fraction = status.progress ?? 0
                            ProgressView(value: fraction)
                                .tint(.blue)
                            Text(tr("Installing %d%%", Int((fraction * 100).rounded())))
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                    }
                    Spacer(minLength: 6)
                    if let status {
                        Button(role: .destructive) {
                            steamStore.cancelDLC(dlc.id, of: gameID)
                        } label: {
                            Label(tr("Cancel"), systemImage: "xmark.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(status.stopping)
                    } else if steamStore.isDLCInstalled(dlc.id, of: gameID) {
                        Button(role: .destructive) {
                            guard let prefixPath,
                                  steamStore.uninstallDLC(dlc.id, of: gameID, prefix: prefixPath) else {
                                presentError(tr("Could not uninstall DLC safely."))
                                return
                            }
                        } label: {
                            Label(tr("Uninstall"), systemImage: "trash")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            guard let prefixPath else {
                                presentError(tr("Windows environment is not ready."))
                                return
                            }
                            steamStore.installDLC(dlc.id, of: gameID, prefix: prefixPath)
                        } label: {
                            Text(tr("Install"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(StoreProviders.of(.steam).hasDownload(String(game.appID)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if dlc.id != dlcs.last?.id {
                    Divider().background(Color.white.opacity(0.08)).padding(.leading, 68)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
