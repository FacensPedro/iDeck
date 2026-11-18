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
    @StateObject private var inputManager = InputManager.shared
    @AppStorage("controllerLeftSensitivity") private var controllerLeftSensitivity = 1.0
    @AppStorage("controllerRightSensitivity") private var controllerRightSensitivity = 1.0
    @AppStorage("controllerDeadzone") private var controllerDeadzone = 0.10
    @AppStorage("wineControllerAPI") private var wineControllerAPI = "By controller"
    @AppStorage("wineJITPoolMiB") private var wineJITPoolMiB = 560
    @AppStorage(BackgroundDownloads.continuedKey) private var continueDownloadsInBackground = true
    @AppStorage(BackgroundDownloads.notificationsKey) private var downloadNotifications = true
    @AppStorage(SystemCoordinator.jitMethodKey) private var jitMethod = "stikdebug"
    @State private var winePoolChangeRequiresRestart = false
    @AppStorage(ResourceGovernor.pauseInBackgroundKey) private var pauseGamesInBackground = true
    @StateObject private var updater = UpdateChecker()
    @State private var ubisoftAccountName = UbisoftSavedSession.load()?.name ?? ""
    @State private var ubisoftLoginPresented = false
    @State private var isSteamSignInPresented = false
    @ObservedObject private var gogLibrary = GOGLibraryModel.shared
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @ObservedObject private var eaLibrary = EALibrary.shared
    @State private var isEASignInPresented = false
    @ObservedObject private var externalDrives = ExternalDrives.shared
    @State private var isGOGSignInPresented = false
    @State private var isEpicSignInPresented = false
    @State private var isPairingImporterPresented = false
    /// iDeck's notifications were refused in iOS Settings.
    @State private var notificationsDenied = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

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
                        SettingsRow(icon: "cpu.fill", color: .green, title: tr("Windows runtime"),
                                    value: tr(MadeiraBundleIdentity.isNative ? "Madeira-native" : "Interface-only"))
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

    private var accountsPage: some View {
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
                LabeledContent(tr("Account"), value: ubisoftAccountName.isEmpty ? tr("Not connected") : ubisoftAccountName)
                if ubisoftAccountName.isEmpty {
                    Button(tr("Sign in")) { ubisoftLoginPresented = true }
                } else {
                    Button(tr("Sign out"), role: .destructive) {
                        if UbisoftSavedSession.clear() { ubisoftAccountName = "" }
                    }
                }
            } header: {
                launcherHeader("Ubisoft Connect", asset: "StoreBadgeUbisoft")
            }
            Section {
                StoreClientButton(client: .ubisoft, coordinator: coordinator, openStore: openStore)
            } footer: {
                Text(tr("The installer is downloaded from Ubisoft when you tap Install. Sign in inside Ubisoft Connect after it opens."))
            }
        }
        .navigationTitle("Ubisoft Connect")
        .sheet(isPresented: $ubisoftLoginPresented) { UbisoftLoginView(accountName: $ubisoftAccountName) }
    }

    @MainActor private func restoreUbisoftSession() async {
        guard let saved = UbisoftSavedSession.load(), saved.expired else { return }
        guard let remember = saved.remember, !remember.isEmpty else {
            if UbisoftSavedSession.clear() { ubisoftAccountName = "" }
            return
        }
        var request = UbisoftSavedSession.request()
        request.setValue("ubi_rm_v1 t=" + remember, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, UbisoftSavedSession.load()?.ticket == saved.ticket,
                  let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                if UbisoftSavedSession.clear() { ubisoftAccountName = "" }
            } else if (200..<300).contains(http.statusCode) {
                let renewed = try UbisoftSavedSession.decode(data, previous: saved)
                try renewed.save()
                ubisoftAccountName = renewed.name
            }
        } catch { return }
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

    // MARK: JIT

    private var jitPage: some View {
        Form {
            settingsSection(title: tr("JIT & Debugging")) {
                statusRow
            }
            Section {
                Picker(tr("Method"), selection: $jitMethod) {
                    Text("StikDebug").tag("stikdebug")
                    Text(tr("Built-in")).tag("builtIn")
                }
                // The pairing file is used only by the built-in method.
                if jitMethod == "builtIn" {
                    LabeledContent(tr("Pairing file"), value: coordinator.hasPairingFile ? tr("Imported") : tr("Missing"))
                    Button(coordinator.hasPairingFile ? tr("Replace pairing file") : tr("Import pairing file")) {
                        isPairingImporterPresented = true
                    }
                }
            } header: {
                Text(tr("Activation"))
            }
            Section {
                Picker(selection: $wineJITPoolMiB) {
                    Text(tr("Automatic")).tag(0)
                    ForEach([384, 512, 560, 624, 640, 768, 896, 1152], id: \.self) { size in
                        Text("\(size) MiB").tag(size)
                    }
                } label: {
                    Text(tr("Wine JIT pool"))
                }
                if winePoolChangeRequiresRestart {
                    Text(tr("Restart iDeck before the new Wine JIT pool size can take effect."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(tr("JIT & Debugging"))
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: coordinator.isJITEnabled ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(coordinator.isJITEnabled ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.isJITEnabled ? tr("JIT detected") : tr("JIT not detected"))
                    .font(.headline)
            }
        }
        .padding(.vertical, 4)
        if coordinator.isJITEnabled {
            LabeledContent(tr("Debugger connection")) {
                Text(coordinator.isStikDebugAttached ? tr("Attached") : tr("Detached"))
                    .foregroundStyle(coordinator.isStikDebugAttached ? .green : .orange)
            }
        }
        if coordinator.isJITEnabled && !coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared {
            Text(tr("JIT permission is active, but StikDebug's debugger script is not connected. Use the button below to reconnect before starting Wine."))
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if !coordinator.isJITEnabled || (!coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared) {
            Button {
                coordinator.requestStikDebugJIT()
            } label: {
                Label(tr(coordinator.isJITEnabled ? "Reconnect JIT debugger" : "Enable JIT"), systemImage: "bolt.fill")
            }
        }
    }

    // MARK: Controls

    private var controlsPage: some View {
        Form {
            settingsSection(title: tr("Controller")) {
                Picker(tr("Windows controller API"), selection: $wineControllerAPI) {
                    ForEach(["By controller", "XInput", "XInput + DirectInput", "HID", "DualSense HID", "Generic HID"], id: \.self) { api in
                        Text(tr(api)).tag(api)
                    }
                }
                LabeledContent(tr("Connected controller")) {
                    Text(inputManager.isControllerConnected ? inputManager.controllerName : tr("Not connected"))
                        .foregroundStyle(inputManager.isControllerConnected ? .green : .secondary)
                }
                if inputManager.isControllerConnected {
                    sensitivityRow(title: tr("Left stick sensitivity"), value: $controllerLeftSensitivity)
                    sensitivityRow(title: tr("Right stick sensitivity"), value: $controllerRightSensitivity)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(tr("Stick dead zone"), value: String(format: "%.2f", controllerDeadzone))
                        Slider(value: $controllerDeadzone, in: 0...0.35, step: 0.01)
                    }
                }
            }
        }
        .navigationTitle(tr("Controls"))
    }

    // MARK: Graphics

    private var graphicsPage: some View {
        Form {
            // The everyday choices only; renderers, memory and sync are under Advanced.
            settingsSection(title: tr("Graphics & Performance")) {
                // Only a display faster than 60 Hz (ProMotion) has a higher rate to hold.
                if UIScreen.main.maximumFramesPerSecond > 60 {
                    toggleRow(title: tr("Hold Display at Maximum Rate"), isOn: $coordinator.isMaxRefreshRateEnabled)
                }
                toggleRow(title: tr("Pause games in the background"), isOn: $pauseGamesInBackground)
            }
            Section {
                NavigationLink(tr("Advanced")) {
                    Form {
                        MadeiraGraphicsSettings()
                        MadeiraMemorySyncSettings()
                    }
                    .navigationTitle(tr("Advanced"))
                }
            }
        }
        .navigationTitle(tr("Graphics & Performance"))
    }

    // MARK: Storage

    private func capacityText(_ capacity: (free: Int64, total: Int64)?) -> String {
        guard let capacity else { return tr("Not connected") }
        return tr("%@ free of %@", ByteCountFormatter.string(fromByteCount: capacity.free, countStyle: .file),
                  ByteCountFormatter.string(fromByteCount: capacity.total, countStyle: .file))
    }

    private var storagePage: some View {
        Form {
            // Free space: this device, then every connected external drive.
            Section(tr("Free space")) {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                LabeledContent(UIDevice.current.model, value: capacityText(ExternalDrives.capacity(of: documents)))
                ForEach(externalDrives.folders) { folder in
                    LabeledContent("\(folder.name) (\(folder.letter):)", value: capacityText(externalDrives.capacity(folder)))
                }
            }
            Section {
                NavigationLink { ExternalDrivesSettingsView() } label: {
                    SettingsRow(icon: "externaldrive.fill", color: .teal, title: tr("External drives"),
                                value: externalDrives.folders.isEmpty ? tr("None") : "\(externalDrives.folders.count)")
                }
                if let missing = externalDrives.installFolderMissing {
                    Text(tr("The install drive \"%@\" is not connected; new games go to this device.", missing))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                toggleRow(title: tr("Continue downloads in the background"), isOn: $continueDownloadsInBackground)
                toggleRow(title: tr("Download notifications"), isOn: $downloadNotifications)
                    .disabled(notificationsDenied)
                if notificationsDenied {
                    Text(tr("Notifications are turned off for iDeck in iOS Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("Downloads"))
            }
        }
        .navigationTitle(tr("Storage & Downloads"))
    }

    // MARK: Runtime

    private var runtimePage: some View {
        Form {
            settingsSection(title: tr("Windows runtime")) {
                let runtime = MadeiraBundleIdentity.profile
                LabeledContent(tr("IPA runtime")) {
                    Text(tr(MadeiraBundleIdentity.isNative ? "Madeira-native" : "Interface-only"))
                        .foregroundStyle(MadeiraBundleIdentity.isNative ? .green : .orange)
                }
                LabeledContent(tr("Graphics profile"), value: MadeiraBundleIdentity.graphicsProfile)
                LabeledContent("Direct3D 11 (DXMT)",
                               value: tr(MadeiraBundleIdentity.d3d11Available ? "Bundled" : "Not bundled"))
                LabeledContent("Direct3D 12 (Madeira)",
                               value: tr(MadeiraBundleIdentity.d3d12Available ? "Bundled" : "Not bundled"))
                LabeledContent("WoW64", value: tr((runtime["wow64Enabled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent("Wine Mono", value: tr((runtime["wineMonoBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent("Metal Shader Converter",
                               value: tr((runtime["metalShaderConverterBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent(tr("Madeira Dock"), value: tr(MadeiraDock.bundled ? "Bundled" : "Not bundled"))
                if !MadeiraBundleIdentity.isNative {
                    Text(tr(MadeiraBundleIdentity.missingRuntimeMessage))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            memoryPlusSection
        }
        .navigationTitle(tr("Windows runtime"))
    }

    // MARK: Memory+

    private func memoryPlusValue(_ state: MemoryPlus.State) -> Text {
        switch state {
        case .granted: return Text(tr("Active")).foregroundColor(.green)
        case .missing: return Text(tr("Not granted")).foregroundColor(.orange)
        case .unknown: return Text(tr("Unknown")).foregroundColor(.secondary)
        }
    }

    /// Memory+ as this installed copy has it, and GetMoreRam's steps when it is missing.
    private var memoryPlusSection: some View {
        settingsSection(title: "Memory+") {
            LabeledContent(tr("Increased Memory Limit")) { memoryPlusValue(MemoryPlus.increasedLimit) }
            LabeledContent(tr("Extended Virtual Addressing")) { memoryPlusValue(MemoryPlus.extendedAddressing) }
            LabeledContent(tr("Memory iOS still allows"), value: "\(ResourceGovernor.availableMiB()) MB")
            LabeledContent("App ID") {
                Text(MemoryPlus.appID).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button(tr("Copy App ID")) { UIPasteboard.general.string = MemoryPlus.appID }
            Link(tr("Open GetMoreRam"), destination: MemoryPlus.getMoreRamURL)
        }
    }

    // MARK: General

    private var languagePicker: some View {
        Picker(selection: $appLanguage) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language.rawValue)
            }
        } label: {
            SettingsRow(icon: "globe", color: .blue, title: tr("Language"))
        }
        .pickerStyle(.menu)
    }

    private var updatesPage: some View {
        Form {
            settingsSection(title: tr("Updates")) {
                ForEach(updater.statuses) { status in
                    LabeledContent(status.project.name, value: versionText(for: status))
                }
                Button {
                    Task { await updater.check() }
                } label: {
                    HStack {
                        Text(updater.isChecking ? tr("Checking...") : tr("Check for Updates"))
                        if updater.isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(updater.isChecking)
            }
            settingsSection(title: tr("Version")) {
                LabeledContent(tr("Installed version"), value: "v\(updater.currentVersion)")
                if updater.availableIDeckUpdate != nil {
                    Button(tr("Install update")) {
                        updater.installIDeckUpdate()
                    }
                }
                Button(tr("View iDeck releases")) {
                    updater.openIDeckReleases()
                }
                if let message = updater.installHandoffMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text(tr("An updated iDeck IPA must be signed and installed by your sideloading app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(tr("Updates"))
    }

    /// Installed iDeck version, plus the newest release with an IPA once checked.
    private func versionText(for status: ProjectStatus) -> String {
        let installed = "v\(updater.currentVersion)"
        guard updater.hasChecked, !status.failed, let latest = status.latest,
              UpdateChecker.isNewer(latest, than: updater.currentVersion) else { return installed }
        return installed + " → " + latest
    }

    // MARK: Building blocks

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        Section(title) { content() }
    }

    private func sensitivityRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title, value: String(format: "%.2fx", value.wrappedValue))
            Slider(value: value, in: 0.25...2.0, step: 0.05)
        }
    }

    /// Reads iDeck's notification permission; when refused, Download notifications
    /// is switched off and greyed out.
    private func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
        if notificationsDenied { downloadNotifications = false }
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
    }
}

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

private struct SettingsStatusPill: View {
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

/// Install (downloads the official installer, then runs it) or Launch for a store's
/// own Windows client, with the download's progress.
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
                Button(tr(installed ? "Launch" : "Install")) {
                    openStore(client)
                }
            }
        }
        .task(id: coordinator.windowsStatus) {
            let result = await Task.detached(priority: .utility) { [client] in client.installedURL != nil }.value
            if !Task.isCancelled { installed = result }
        }
    }
}

/// A store page's card for a store whose games iDeck does not list (Ubisoft Connect).
struct StoreClientCard: View {
    let client: SystemCoordinator.StoreClient
    @ObservedObject var coordinator: SystemCoordinator

    @State private var installed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(client.rawValue)
                .font(.headline)
                .foregroundColor(.white)
            Text(tr(!installed
                ? "Install it in Settings › Stores & launchers › %@."
                : "Installed. Open it to sign in and play your games.", client.rawValue))
                .font(.subheadline)
                .foregroundColor(.gray)
            if installed {
                Button(tr("Launch")) { coordinator.openStoreClient(client) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: coordinator.windowsStatus) {
            let result = await Task.detached(priority: .utility) { [client] in client.installedURL != nil }.value
            if !Task.isCancelled { installed = result }
        }
    }
}


private struct UbisoftLoginView: View {
    @Binding var accountName: String
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var challenge: String?
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""
    @State private var request: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if challenge == nil {
                    TextField(tr("Email"), text: $email)
                        .keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(tr("Password"), text: $password).textContentType(.password)
                } else {
                    TextField(tr("Verification code"), text: $code).textContentType(.oneTimeCode)
                }
                Button(tr("Sign in")) {
                    busy = true
                    request = Task { await authenticate() }
                }
                .disabled(busy || (challenge == nil ? email.isEmpty || password.isEmpty : code.isEmpty))
                if busy { ProgressView() }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Ubisoft Connect")
            .safeAreaInset(edge: .bottom) {
                Link(tr("Ubisoft account"), destination: URL(string: "https://account.ubisoft.com/")!)
                    .padding()
            }
            .toolbar { Button(tr("Cancel")) { dismiss() } }
        }
        .onDisappear { request?.cancel() }
    }

    @MainActor private func authenticate() async {
        defer { busy = false }
        error = ""
        var login = UbisoftSavedSession.request()
        if let challenge {
            login.setValue("ubi_2fa_v1 t=" + challenge, forHTTPHeaderField: "Authorization")
            login.setValue(code, forHTTPHeaderField: "Ubi-2FACode")
        } else {
            let credentials = Data((email.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + password).utf8)
            login.setValue("Basic " + credentials.base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: login)
            try Task.checkCancellation()
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let token = fields?["twoFactorAuthenticationTicket"] as? String, !token.isEmpty {
                challenge = token
                password = ""
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  fields?["ticket"] is String,
                  let name = fields?["nameOnPlatform"] as? String, !name.isEmpty else {
                error = (fields?["message"] as? String) ?? tr("Sign-in failed")
                return
            }
            try UbisoftSavedSession.decode(data).save()
            accountName = name
            dismiss()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private struct UbisoftSavedSession: Codable {
    let name: String
    let ticket: String
    let remember: String?
    let expiry: Date
    let sessionID: String?
    var expired: Bool { expiry <= Date() }

    static func request() -> URLRequest {
        var login = URLRequest(url: URL(string: "https://public-ubiservices.ubi.com/v3/profiles/sessions")!)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue("39baebad-39e5-4552-8c25-2c9b919064e2", forHTTPHeaderField: "Ubi-AppId")
        login.httpBody = Data(#"{"rememberMe":true}"#.utf8)
        return login
    }

    static func decode(_ data: Data, previous: Self? = nil) throws -> Self {
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let name = fields?["nameOnPlatform"] as? String, !name.isEmpty,
              let ticket = fields?["ticket"] as? String, !ticket.isEmpty,
              let timestamp = fields?["expiration"] as? String else { throw URLError(.cannotParseResponse) }
        let format = ISO8601DateFormatter()
        let seconds = format.date(from: timestamp)
        format.formatOptions.insert(.withFractionalSeconds)
        guard let expiry = seconds ?? format.date(from: timestamp) else { throw URLError(.cannotParseResponse) }
        return Self(name: name, ticket: ticket, remember: fields?["rememberMeTicket"] as? String ?? previous?.remember,
                    expiry: expiry, sessionID: fields?["sessionId"] as? String)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "iDeck.Ubisoft", kSecAttrAccount as String: "session"]
    }

    static func load() -> Self? {
        var search = query
        search[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func clear() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
