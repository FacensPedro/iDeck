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

    var downloadStatus: some View {
        let progress = steamLibrary.downloadProgress[game.appID]
        let stopping = steamLibrary.cancellingApps.contains(game.appID)
        return VStack(spacing: 10) {
            ProgressView(value: progress?.phase == .checking
                         ? (progress.map { $0.checkTotal > 0 ? min(1, Double($0.checkDone) / Double($0.checkTotal)) : 0 } ?? 0)
                         : (progress?.fraction ?? 0))
            Text(steamLibrary.waitingApps.contains(game.appID) ? tr("Waiting") :
                 progress?.phase == .preparing ? tr("Preparing download...") :
                 progress?.phase == .checking ? tr("Checking existing files %d%%", Int(((progress.map { $0.checkTotal > 0 ? min(1, Double($0.checkDone) / Double($0.checkTotal)) : 0 } ?? 0) * 100).rounded())) :
                 progress?.phase == .finishing ? tr("Finishing installation...") :
                 tr("Installing %d%%", Int(((progress?.fraction ?? 0) * 100).rounded())))
                .font(.caption)
                .foregroundColor(.white)
            if let progress, progress.phase == .downloading,
               let eta = DownloadETA.seconds(done: progress.doneBytes,
                                             total: progress.totalBytes,
                                             bytesPerSecond: progress.bytesPerSecond),
               let remaining = DownloadETA.label(eta) {
                Label(tr("Time left") + ": " + remaining, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let progress, progress.installedBytes > 0 {
                Text(tr("Installed: %@", ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: progress.installedBytes), countStyle: .file)))
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            if steamLibrary.canCancelInstall(appID: game.appID) {
                // Pause keeps the files; Stop uninstalls the game.
                HStack(spacing: 10) {
                    Button {
                        steamLibrary.pauseInstall(appID: game.appID)
                    } label: {
                        Label(tr("Pause"), systemImage: "pause.fill")
                            .downloadControlLabel()
                    }
                    .disabled(stopping)
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    Button(role: .destructive) {
                        steamLibrary.cancelInstall(appID: game.appID)
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

    /// A DLC's size: its own depots in the game's app info (where Steam lists
    /// DLC content), else the DLC app's own download size.
    func dlcSize(_ id: UInt32) -> String? {
        var bytes = game.depots.filter { $0.dlcAppID == id }.reduce(UInt64(0)) { $0 + max($1.maxSize, $1.publicSizeBytes) }
        if bytes == 0 { bytes = steamLibrary.dlcMetadata[id]?.downloadSize(for: "windows") ?? 0 }
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    var dlcList: some View {
        VStack(spacing: 0) {
            let ids = steamLibrary.availableDLC[game.appID] ?? []
            if ids.isEmpty {
                DetailRow(title: tr("No DLC found for this game"), showsDivider: false) { EmptyView() }
            }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 12) {
                    SteamDLCArtworkView(appID: id)
                        .frame(width: 92, height: 43)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(steamLibrary.dlcMetadata[id]?.name ?? "DLC \(id)")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                        if let size = dlcSize(id) {
                            Text(size)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        if steamLibrary.installingDLC[game.appID] == id {
                            let fraction = steamLibrary.downloadProgress[game.appID]?.fraction ?? 0
                            ProgressView(value: fraction)
                                .tint(.blue)
                            Text(tr("Installing %d%%", Int((fraction * 100).rounded())))
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                    }
                    Spacer(minLength: 6)
                    if steamLibrary.installingDLC[game.appID] == id {
                        Button(role: .destructive) {
                            steamLibrary.cancelDLCInstall(appID: game.appID, dlcAppID: id)
                        } label: {
                            Label(tr("Cancel"), systemImage: "xmark.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(steamLibrary.cancellingDLC.contains(id))
                    } else if steamLibrary.installedDLC[game.appID]?.contains(id) == true {
                        Button(role: .destructive) {
                            guard let prefixPath,
                                  steamLibrary.uninstallDLC(appID: game.appID,
                                                            dlcAppID: id, prefixPath: prefixPath) else {
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
                            steamLibrary.startDLCInstall(appID: game.appID,
                                                        dlcAppID: id, prefixPath: prefixPath)
                        } label: {
                            Text(tr("Install"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(steamLibrary.installingApps.contains(game.appID))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if id != ids.last {
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
