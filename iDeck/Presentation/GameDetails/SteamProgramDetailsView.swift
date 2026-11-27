// SteamProgramDetailsView.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

struct SteamProgramDetailsView: View {
    let game: SteamAppInfo
    let prefixPath: URL?
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var steamLibrary: SteamOwnedGamesModel
    @ObservedObject var coordinator: SystemCoordinator
    var launch: (SteamAppInfo) -> Void = { _ in }
    @Environment(\.dismiss) var dismiss
    @State var profile: WindowsGameProfile
    @State var errorMessage: String?
    @State var showError = false
    @State var confirmUninstall = false

    init(game: SteamAppInfo, prefixPath: URL?, library: WindowsLibraryStore,
         steamLibrary: SteamOwnedGamesModel, coordinator: SystemCoordinator,
         launch: @escaping (SteamAppInfo) -> Void = { _ in }) {
        self.launch = launch
        self.game = game
        self.prefixPath = prefixPath
        self.library = library
        self.steamLibrary = steamLibrary
        self.coordinator = coordinator
        let initial = library.profile(for: "steam:\(game.appID)", title: game.name)
        _profile = State(initialValue: initial)
    }

    var installed: Bool {
        guard let prefixPath else { return false }
        return steamLibrary.isInstalled(appID: game.appID, prefixPath: prefixPath)
    }

    var installing: Bool {
        steamLibrary.installingApps.contains(game.appID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    SteamGameBannerView(game: game)
                        .frame(maxWidth: .infinity)
                    Text(game.name)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        DetailChip(text: installed ? tr("Installed") : tr("Not installed"),
                                   systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                                   tint: installed ? .green : .gray)
                        if let size = installedSizeText {
                            DetailChip(text: size, systemImage: "internaldrive", tint: .gray)
                        }
                    }
                    .onAppear { steamLibrary.loadOwnedDepots() }
                    if steamLibrary.pausedInstalls.contains(game.appID) {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Button {
                                    steamLibrary.resumeInstall(appID: game.appID)
                                } label: {
                                    Label(tr("Resume"), systemImage: "play.fill")
                                        .downloadControlLabel()
                                }
                                .buttonStyle(.borderedProminent)
                                Button(role: .destructive) {
                                    steamLibrary.cancelInstall(appID: game.appID)
                                } label: {
                                    Label(tr("Stop"), systemImage: "stop.fill")
                                        .downloadControlLabel()
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.red)
                            }
                        }
                    } else if installing {
                        downloadStatus
                    } else if installed {
                      // Launch and Uninstall side by side; Uninstall asks first.
                      HStack(spacing: 10) {
                        // Starts the game; without JIT, StikDebug opens first.
                        Button {
                            dismiss()
                            launch(game)
                        } label: {
                            Label(tr("Launch"), systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: 220)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .destructive) { confirmUninstall = true } label: {
                            Label(tr("Uninstall"), systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: 220)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                      }
                      .alert(tr("Delete this game's files?"), isPresented: $confirmUninstall) {
                        Button(tr("Cancel"), role: .cancel) {}
                        Button(tr("Uninstall"), role: .destructive) {
                            guard let prefixPath else {
                                presentError(tr("Windows environment is not ready."))
                                return
                            }
                            if steamLibrary.uninstall(appID: game.appID, prefixPath: prefixPath) {
                                library.removeProfile(for: "steam:\(game.appID)")
                                dismiss()
                            } else {
                                presentError(tr("Steam could not safely remove this game's files. Refresh the library and try again."))
                            }
                        }
                      }
                    } else if AntiCheatPolicy.isBlocked(title: game.name, steamAppID: game.appID) {
                        AntiCheatBlockedButton()
                    } else {
                        Button {
                            guard let prefixPath else {
                                presentError(tr("Windows environment is not ready."))
                                return
                            }
                            steamLibrary.startInstall(appID: game.appID, prefixPath: prefixPath)
                        } label: {
                            Label(tr("Install"), systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: 220)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(prefixPath == nil || !game.installableOnWindows)
                        // A failed or stopped download leaves its files behind; without
                        // this the only way to get the space back was to install again.
                        if let prefixPath, steamLibrary.hasLeftoverFiles(appID: game.appID, prefixPath: prefixPath) {
                            Button(role: .destructive) {
                                if !steamLibrary.deleteLeftoverFiles(appID: game.appID, prefixPath: prefixPath) {
                                    presentError(tr("Could not remove this game's files."))
                                }
                            } label: {
                                Label(tr("Delete downloaded files"), systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let error = steamLibrary.downloadErrors[game.appID] {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    GameLanguageCard(profileID: "steam:\(game.appID)",
                                     available: game.languages.isEmpty ? nil : GameLanguage.all.map(\.steam).filter(game.languages.contains).compactMap(GameLanguage.tag(steam:)),
                                     audio: Set(game.audioLanguages.compactMap(GameLanguage.tag(steam:))),
                                     subtitles: Set(game.subtitleLanguages.compactMap(GameLanguage.tag(steam:))),
                                     onChosen: { _ in
                                         // An installed game fetches the chosen language's depots
                                         // (dubbing and subtitles) through the update path.
                                         guard let prefixPath, steamLibrary.installedApps.contains(game.appID) else { return }
                                         AppLog.record("[game-language] steam:\(game.appID): fetching the language files")
                                         steamLibrary.startInstall(appID: game.appID, prefixPath: prefixPath)
                                     })
                    WindowsGameProfileForm(profile: $profile)
                    DetailCard(title: tr("Steam Cloud saves"), footer: steamLibrary.cloudMessages[game.appID]) {
                        steamCloudControls
                    }
                    SteamAchievementsCard(appID: game.appID)
                    if installed {
                        DetailCard(title: tr("DLCs")) {
                            dlcList
                        }
                    }
                }
                .padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Game details"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: steamLibrary.installingDLC[game.appID]) { _, now in
                if now == nil, let prefixPath { steamLibrary.refreshInstalledDLC(appID: game.appID, prefixPath: prefixPath) }
            }
            .task(id: game.appID) {
                await steamLibrary.loadDLC(appID: game.appID)
                guard !Task.isCancelled else { return }
                if let prefixPath {
                    steamLibrary.refreshInstalledDLC(appID: game.appID, prefixPath: prefixPath)
                    guard !Task.isCancelled else { return }
                    if autoSaveEnabled {
                        await steamLibrary.syncCloud(appID: game.appID, prefixPath: prefixPath)
                    }
                }
            }
            // Settings are saved as they change (2.13.3): no Save or Done button.
            .onChange(of: profile) { _, changed in library.save(changed) }
            .alert(tr("Operation failed"), isPresented: $showError) {
                Button(tr("OK"), role: .cancel) { }
            } message: {
                Text(errorMessage ?? tr("Unknown error"))
            }
        }
        .preferredColorScheme(.dark)
    }

    @AppStorage(SteamCloudAutoSave.key) var autoSaveEnabled = false

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
    private func dlcSize(_ id: UInt32) -> String? {
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

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
