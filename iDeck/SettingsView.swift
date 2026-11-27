import SwiftUI
import Security
import UserNotifications
import UniformTypeIdentifiers

/// Settings: a grouped list of categories, each opening its own page.
struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    var openStore: (SystemCoordinator.StoreClient) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject var inputManager = InputManager.shared
    @AppStorage("controllerLeftSensitivity") var controllerLeftSensitivity = 1.0
    @AppStorage("controllerRightSensitivity") var controllerRightSensitivity = 1.0
    @AppStorage("controllerDeadzone") var controllerDeadzone = 0.10
    @AppStorage("wineControllerAPI") var wineControllerAPI = "By controller"
    @AppStorage(VirtualSwap.enabledKey) var virtualSwap = true
    @State var autoDLLNotice: String?
    @AppStorage("wineJITPoolMiB") var wineJITPoolMiB = 560
    @AppStorage(BackgroundDownloads.continuedKey) var continueDownloadsInBackground = true
    @AppStorage(BackgroundDownloads.notificationsKey) var downloadNotifications = true
    @AppStorage(SystemCoordinator.jitMethodKey) var jitMethod = "stikdebug"
    @State var winePoolChangeRequiresRestart = false
    @AppStorage(ResourceGovernor.pauseInBackgroundKey) var pauseGamesInBackground = true
    @StateObject var updater = UpdateChecker()
    @State var ubisoftAccountName = UbisoftSavedSession.load()?.name ?? ""
    @State var ubisoftLoginPresented = false
    /// The saved Ubisoft session could not be renewed. The account stays saved (only
    /// Sign out removes it, as for the other stores); signing in again updates it.
    @State var ubisoftSessionExpired = false
    @State var isSteamSignInPresented = false
    @ObservedObject var gogLibrary = GOGLibraryModel.shared
    @ObservedObject var epicLibrary = EpicLibrary.shared
    @ObservedObject var eaLibrary = EALibrary.shared
    @State var isEASignInPresented = false
    @ObservedObject var externalDrives = ExternalDrives.shared
    @State var isGOGSignInPresented = false
    @State var isEpicSignInPresented = false
    @State var isPairingImporterPresented = false
    /// iDeck's notifications were refused in iOS Settings.
    @State var notificationsDenied = false
    @AppStorage(AppLanguage.storageKey) var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                overviewSection

                Section(tr("Services")) {
                    NavigationLink { accountsPage } label: {
                        SettingsRow(icon: "square.grid.2x2.fill", color: .blue,
                                    title: tr("Stores & launchers"))
                    }
                }

                Section(tr("Windows")) {
                    NavigationLink { jitPage } label: {
                        SettingsRow(icon: "bolt.fill", color: .orange, title: tr("JIT & Debugging"),
                                    value: coordinator.isJITEnabled ? tr("Active") : tr("Off"))
                    }
                    NavigationLink { graphicsPage } label: {
                        SettingsRow(icon: "sparkles.tv.fill", color: .pink, title: tr("Graphics & Performance"))
                    }
                    NavigationLink { controlsPage } label: {
                        SettingsRow(icon: "gamecontroller", color: .indigo, title: tr("Controls"),
                                    value: inputManager.isControllerConnected ? inputManager.controllerName : nil)
                    }
                    NavigationLink { storagePage } label: {
                        SettingsRow(icon: "externaldrive.fill", color: .teal, title: tr("Storage & Downloads"),
                                    value: externalDrives.folders.isEmpty ? nil : "\(externalDrives.folders.count)")
                    }
                    NavigationLink { runtimePage } label: {
                        // The runtime kind is shown only on the page, as "IPA runtime".
                        SettingsRow(icon: "cpu.fill", color: .green, title: tr("Windows runtime"))
                    }
                }

                Section(tr("General")) {
                    Button {
                        UserDefaults.standard.set(false, forKey: "firstRunSetup.complete.v1")
                        dismiss()
                    } label: {
                        HStack(spacing: 0) {
                            SettingsRow(icon: "wand.and.stars", color: .indigo, title: tr("Initial setup"))
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(tr("Opens the initial setup again"))

                    languagePicker
                    NavigationLink { updatesPage } label: {
                        SettingsRow(icon: "arrow.triangle.2.circlepath", color: .blue, title: tr("Updates"),
                                    value: "v\(updater.currentVersion)")
                    }
                }

                settingsSection(title: tr("Support")) {
                    NavigationLink(destination: BugReportView()) {
                        SettingsRow(icon: "ladybug.fill", color: .red, title: tr("Bugs & logs"))
                    }
                }
            }
            .task { await restoreUbisoftSession() }
            .navigationTitle(tr("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Done")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isSteamSignInPresented) { SteamSignInView() }
        .sheet(isPresented: $isGOGSignInPresented) { GOGSignInView() }
        .sheet(isPresented: $isEpicSignInPresented) { EpicSignInView() }
        .fileImporter(isPresented: $isPairingImporterPresented,
                      allowedContentTypes: [.propertyList, .xml, .json, .data]) { result in
            if case .success(let url) = result { coordinator.importPairingFile(at: url) }
        }
        .task {
            inputManager.refreshControllers()
            coordinator.refreshJITStatus()
            coordinator.refreshPairingFileState()
            await refreshNotificationPermission()
            await updater.check()
        }
        .onChange(of: downloadNotifications) { _, on in
            // Turning it on asks iOS; Don't Allow (now or earlier) turns it back off.
            guard on else { return }
            Task {
                let center = UNUserNotificationCenter.current()
                var status = await center.notificationSettings().authorizationStatus
                if status == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                    status = await center.notificationSettings().authorizationStatus
                }
                if status == .denied || status == .notDetermined {
                    downloadNotifications = false
                    notificationsDenied = status == .denied
                }
            }
        }
        .onChange(of: wineJITPoolMiB) { _, selected in
            winePoolChangeRequiresRestart = !coordinator.updateWineJITPoolPreference(selected)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshJITStatus()
                Task { await refreshNotificationPermission() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Overview

    private var overviewSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("iDeck").font(.headline)
                    Text("v\(updater.currentVersion)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    SettingsStatusPill(text: coordinator.isJITEnabled ? tr("JIT active") : tr("JIT off"),
                               color: coordinator.isJITEnabled ? .green : .orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Accounts

    // MARK: JIT

    // MARK: Controls

    // MARK: Graphics

    // MARK: Storage

    // MARK: Runtime

    // MARK: Memory+

    // MARK: General

    // MARK: Building blocks

}

