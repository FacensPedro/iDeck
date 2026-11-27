// StoreGameDetailsView.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

/// The game page shared by GOG and Epic: the same banner, cover, title,
/// actions and per-game settings as a Steam game's page. Store-specific
/// rows (Epic's version, update, repair, cloud saves) go in `extra`.
struct StoreGameDetailsView<Extra: View>: View {
    let title: String
    let store: GameStore
    let profileID: String
    let covers: [URL]
    let banners: [URL]
    let installed: Bool
    /// Install progress 0...1 while downloading or installing.
    let progress: Double?
    let etaSeconds: Int?
    /// Bytes on the device so far while installing ("1.2 GB / 4 GB"), as a Steam game's page shows.
    let installedText: String?
    let paused: Bool
    /// Queued behind another game's download: "Waiting" instead of a percentage.
    let waiting: Bool
    let sizeText: String?
    let errorText: String?
    let canInstall: Bool
    let onLaunch: () -> Void
    let onInstall: () -> Void
    let onPause: (() -> Void)?
    let onStop: () -> Void
    let onUninstall: (() -> Bool)?
    @ObservedObject var library: WindowsLibraryStore
    @ObservedObject var coordinator: SystemCoordinator
    @ViewBuilder var extra: Extra
    @Environment(\.dismiss) var dismiss
    @State var profile: WindowsGameProfile
    @State var confirmUninstall = false
    @State var errorMessage: String?

    init(title: String, store: GameStore, profileID: String, covers: [URL], banners: [URL],
         installed: Bool, progress: Double?, etaSeconds: Int? = nil, installedText: String? = nil,
         paused: Bool = false, waiting: Bool = false, sizeText: String?, errorText: String?,
         canInstall: Bool, onLaunch: @escaping () -> Void, onInstall: @escaping () -> Void,
         onPause: (() -> Void)? = nil, onStop: @escaping () -> Void, onUninstall: (() -> Bool)?,
         library: WindowsLibraryStore, coordinator: SystemCoordinator,
         @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.store = store
        self.profileID = profileID
        self.covers = covers
        self.banners = banners
        self.installed = installed
        self.progress = progress
        self.etaSeconds = etaSeconds
        self.installedText = installedText
        self.paused = paused
        self.waiting = waiting
        self.sizeText = sizeText
        self.errorText = errorText
        self.canInstall = canInstall
        self.onLaunch = onLaunch
        self.onInstall = onInstall
        self.onPause = onPause
        self.onStop = onStop
        self.onUninstall = onUninstall
        self.library = library
        self.coordinator = coordinator
        self.extra = extra()
        let initial = library.profile(for: profileID, title: title)
        _profile = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    StoreBannerView(urls: banners + covers)
                    Text(title)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack(spacing: 8) {
                        DetailChip(text: installed ? tr("Installed") : tr("Not installed"),
                                   systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                                   tint: installed ? .green : .gray)
                        DetailChip(text: sizeText ?? tr("Calculating..."), systemImage: "internaldrive", tint: .gray)
                    }

                    actions

                    if let errorText {
                        Text(errorText)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    GameLanguageCard(profileID: profileID, available: GameLanguage.known(profileID))
                    WindowsGameProfileForm(profile: $profile)
                    extra
                }
                .padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(tr("Game details"))
            .navigationBarTitleDisplayMode(.inline)
            // Settings are saved as they change (2.13.3): no Save or Done button.
            .onChange(of: profile) { _, changed in library.save(changed) }
            .alert(tr("Delete this game's files?"), isPresented: $confirmUninstall) {
                Button(tr("Cancel"), role: .cancel) {}
                Button(tr("Uninstall"), role: .destructive) {
                    if onUninstall?() == true {
                        library.removeProfile(for: profileID)
                        dismiss()
                    } else {
                        errorMessage = tr("Could not remove this game's files.")
                    }
                }
                Button(tr("Cancel"), role: .cancel) {}
            }
            .alert(tr("Operation failed"), isPresented: Binding(get: { errorMessage != nil },
                                                                 set: { if !$0 { errorMessage = nil } })) {
                Button(tr("OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder var actions: some View {
        if let progress, !paused {
            VStack(spacing: 10) {
                ProgressView(value: waiting ? 0 : progress)
                Text(waiting ? tr("Waiting") : tr("Installing %d%%", Int((progress * 100).rounded())))
                    .font(.caption)
                    .foregroundColor(.white)
                if let etaSeconds, let eta = DownloadETA.label(etaSeconds) {
                    Label(tr("Time left") + ": " + eta, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let installedText {
                    Text(tr("Installed: %@", installedText))
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                // Pause keeps the files; Stop uninstalls the game.
                HStack(spacing: 10) {
                    if let onPause {
                        Button(action: onPause) {
                            Label(tr("Pause"), systemImage: "pause.fill")
                                .downloadControlLabel()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                    }
                    Button(role: .destructive, action: onStop) {
                        Label(tr("Stop"), systemImage: "stop.fill")
                            .downloadControlLabel()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
        } else if installed {
          HStack(spacing: 10) {
            // Starts the game; without JIT, StikDebug opens first.
            Button {
                dismiss()
                onLaunch()
            } label: {
                Label(tr("Launch"), systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 220)
                    .frame(height: 36)
            }
            .buttonStyle(.borderedProminent)
            if onUninstall != nil {
                Button(role: .destructive) { confirmUninstall = true } label: {
                    Label(tr("Uninstall"), systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: 220)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
            }
          }
        } else if AntiCheatPolicy.isBlocked(profileID: profileID, title: title) {
            AntiCheatBlockedButton()
        } else if canInstall {
            // A paused or failed download keeps its files: Stop beside Resume removes them.
            HStack(spacing: 10) {
                Button(action: onInstall) {
                    Label(tr(paused ? "Resume" : "Install"),
                          systemImage: paused ? "play.circle.fill" : "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: 220)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                if paused || errorText != nil {
                    Button(role: .destructive, action: onStop) {
                        Label(tr("Stop"), systemImage: "stop.fill")
                            .downloadControlLabel()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
            }
        } else {
            Text(tr("Not available for Windows"))
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

/// "1.2 GB / 4 GB": what a download has put on the device so far, of its total.
func installedBytesText(done: UInt64, total: UInt64, showZero: Bool = false) -> String? {
    guard total > 0, done > 0 || showZero else { return nil }
    let format = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
    return format(min(done, total)) + " / " + format(total)
}
