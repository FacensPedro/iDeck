// Settings: Steam, GOG, Epic Games, EA app and Ubisoft Connect pages.
// Split from SettingsView.swift (iDeck 3.0 architecture).

import SwiftUI

extension SettingsView {
    private var steamPage: some View {
        Form {
            settingsSection(title: tr("Steam")) {
                LabeledContent(tr("Steam account")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(coordinator.isSteamConnected ? tr("Connected") : tr("Not connected"))
                            .foregroundStyle(coordinator.isSteamConnected ? .green : .secondary)
                        if coordinator.isSteamConnected, let account = SteamSignIn.accountName {
                            Text(account).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if coordinator.isSteamConnected {
                    Button(tr("Disconnect Steam"), role: .destructive) { coordinator.disconnectSteamAccount() }
                } else {
                    Button(tr("Connect Steam")) { isSteamSignInPresented = true }
                }
            }
            Section {
                LabeledContent(tr("Madeira Dock"), value: tr(MadeiraDock.bundled ? "Bundled" : "Not bundled"))
                LabeledContent(tr("Steam client components"),
                               value: MadeiraDock.clientInstalled
                                   ? tr(MadeiraDock.clientSupported ? "Ready" : "Unsupported build")
                                   : tr("Not downloaded"))
            } header: {
                Text(tr("Steam client"))
            }
        }
        .navigationTitle("Steam")
    }

    private var gogPage: some View {
        Form {
            settingsSection(title: tr("GOG")) {
                LabeledContent(tr("Account"),
                               value: gogLibrary.isSignedIn ? (gogLibrary.username ?? tr("Connected")) : tr("Not connected"))
                if gogLibrary.isSignedIn {
                    Button(tr("Sign out"), role: .destructive) { gogLibrary.signOut() }
                } else {
                    Button(tr("Connect GOG")) { isGOGSignInPresented = true }
                }
            }
        }
        .navigationTitle("GOG")
    }

    private var epicPage: some View {
        Form {
            Section {
                LabeledContent(tr("Account"),
                               value: epicLibrary.signedIn ? (epicLibrary.accountName ?? tr("Connected")) : tr("Not connected"))
                if epicLibrary.signedIn {
                    Button(tr("Sign out"), role: .destructive) { epicLibrary.signOut() }
                } else {
                    Button(tr("Connect Epic")) { isEpicSignInPresented = true }
                }
            } header: {
                Text("Epic Games")
            }
            if epicLibrary.signedIn {
                Section(tr("Cloud saves")) {
                    EpicCloudSettingRows()
                }
            }
        }
        .navigationTitle("Epic Games")
        .onAppear { epicLibrary.start() }
    }

    var accountsPage: some View {
        Form {
            Section(tr("Game stores")) {
                NavigationLink { steamPage } label: {
                    SettingsRow(icon: "gamecontroller.fill", color: .blue, title: "Steam",
                                value: coordinator.isSteamConnected ? (SteamSignIn.accountName ?? tr("Connected")) : tr("Not connected"),
                                asset: "StoreBadgeSteam", assetKeepsColors: true)
                }
            }
            Section {
                NavigationLink { gogPage } label: {
                    SettingsRow(icon: "shippingbox.fill", color: .purple, title: "GOG",
                                value: gogLibrary.isSignedIn ? (gogLibrary.username ?? tr("Connected")) : tr("Not connected"),
                                asset: "StoreBadgeGOG", assetPlain: true)
                }
            }
            Section {
                NavigationLink { epicPage } label: {
                    SettingsRow(icon: "e.square.fill", color: .black, title: "Epic Games",
                                value: epicLibrary.signedIn ? (epicLibrary.accountName ?? tr("Connected")) : tr("Not connected"),
                                asset: "StoreBadgeEpic")
                }
            }
            Section {
                NavigationLink { ubisoftPage } label: {
                    SettingsRow(icon: "u.square.fill", color: .black, title: "Ubisoft Connect",
                                value: ubisoftAccountName.isEmpty ? tr("Not connected") : ubisoftAccountName,
                                asset: "StoreBadgeUbisoft", assetKeepsColors: true)
                }
            }
            Section {
                NavigationLink { eaPage } label: {
                    SettingsRow(icon: "square.stack", color: .blue, title: "EA app",
                                value: eaLibrary.signedIn ? (eaLibrary.accountName ?? tr("Connected")) : tr("Not connected"),
                                asset: "StoreBadgeEA", assetKeepsColors: true)
                }
            }
        }
        .navigationTitle(tr("Stores & launchers"))
    }

    private var ubisoftPage: some View {
        Form {
            Section {
                if !ubisoftAccountName.isEmpty, ubisoftSessionExpired {
                    Label(tr("Session expired. Sign in again to continue."), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                LabeledContent(tr("Account"), value: ubisoftAccountName.isEmpty ? tr("Not connected") : ubisoftAccountName)
                if ubisoftAccountName.isEmpty {
                    Button(tr("Sign in")) { ubisoftLoginPresented = true }
                } else {
                    if ubisoftSessionExpired {
                        Button(tr("Sign in again")) { ubisoftLoginPresented = true }
                    }
                    Button(tr("Sign out"), role: .destructive) {
                        UbisoftSavedLogin.remove()
                        if UbisoftSavedSession.clear() { ubisoftAccountName = ""; UbisoftLibrary.shared.refresh() }
                    }
                }
            } header: {
                launcherHeader("Ubisoft Connect", asset: "StoreBadgeUbisoft")
            }
            Section {
                StoreClientButton(client: .ubisoft, coordinator: coordinator, openStore: openStore)
            }
        }
        .navigationTitle("Ubisoft Connect")
        .sheet(isPresented: $ubisoftLoginPresented, onDismiss: { Task { await restoreUbisoftSession() } }) {
            UbisoftLoginView(accountName: $ubisoftAccountName)
        }
    }

    /// Renews an expired Ubisoft session with its remember-me ticket. Nothing here
    /// removes the saved account: a refused or failed renewal only marks the session
    /// expired, and Sign out is the one way to remove it (as for Steam, GOG, Epic and EA).
    /// The session lives in the Keychain, which iOS keeps when the app is deleted.
    @MainActor func restoreUbisoftSession() async {
        guard let saved = UbisoftSavedSession.load() else {
            ubisoftSessionExpired = false
            return
        }
        ubisoftAccountName = saved.name
        guard saved.expired else {
            ubisoftSessionExpired = false
            return
        }
        let renewed = await UbisoftSavedSession.current()
        guard !Task.isCancelled else { return }
        if let renewed, !renewed.expired {
            ubisoftAccountName = renewed.name
            ubisoftSessionExpired = false
            UbisoftLibrary.shared.refresh()
        } else {
            ubisoftSessionExpired = true
        }
    }

    private var eaPage: some View {
        Form {
            Section {
                LabeledContent(tr("Account"),
                               value: eaLibrary.signedIn ? (eaLibrary.accountName ?? tr("Connected")) : tr("Not connected"))
                if eaLibrary.signedIn {
                    Button(tr("Sign out"), role: .destructive) { eaLibrary.signOut() }
                } else {
                    Button(tr("Connect EA")) { isEASignInPresented = true }
                }
            } header: {
                launcherHeader("EA app", asset: "StoreBadgeEA")
            }
            Section {
                StoreClientButton(client: .ea, coordinator: coordinator, openStore: openStore)
            }
        }
        .navigationTitle("EA app")
        .onAppear { eaLibrary.start() }
        .sheet(isPresented: $isEASignInPresented) { EASignInView() }
    }

    private func launcherHeader(_ title: String, asset: String) -> some View {
        HStack(spacing: 10) {
            Image(asset).renderingMode(.original).resizable().scaledToFit().frame(width: 36, height: 36)
            Text(title)
        }
        .textCase(nil)
    }
}
