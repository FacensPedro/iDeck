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

    /// The download state, through the StoreProvider (3.0.1).
    var status: StoreDownloadStatus? { StoreProviders.of(.steam).downloadStatus(String(game.appID)) }

    var installing: Bool {
        guard let status else { return false }
        if case .failed = status.state { return false }
        return status.state != .paused
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
                    if status?.isPaused == true {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Button {
                                    StoreProviders.of(.steam).resume(String(game.appID), prefix: prefixPath)
                                } label: {
                                    Label(tr("Resume"), systemImage: "play.fill")
                                        .downloadControlLabel()
                                }
                                .buttonStyle(.borderedProminent)
                                Button(role: .destructive) {
                                    StoreProviders.of(.steam).cancel(String(game.appID))
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
                            if StoreProviders.of(.steam).uninstall(String(game.appID), prefix: prefixPath) {
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
                            StoreProviders.of(.steam).install(String(game.appID), prefix: prefixPath)
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

                    if let error = status?.failure {
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
                                         guard let prefixPath, StoreProviders.of(.steam).installedIDs.contains(String(game.appID)) else { return }
                                         AppLog.record("[game-language] steam:\(game.appID): fetching the language files")
                                         StoreProviders.of(.steam).install(String(game.appID), prefix: prefixPath)
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

}
