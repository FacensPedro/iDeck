import SwiftUI
import UniformTypeIdentifiers

/// Settings: a grouped list of categories, each opening its own page.
struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var inputManager = InputManager.shared
    @ObservedObject private var hardwareInput = HardwareInput.shared
    @AppStorage("controllerLeftSensitivity") private var controllerLeftSensitivity = 1.0
    @AppStorage("controllerRightSensitivity") private var controllerRightSensitivity = 1.0
    @AppStorage("controllerDeadzone") private var controllerDeadzone = 0.10
    @AppStorage("wineControllerAPI") private var wineControllerAPI = "XInput"
    @AppStorage("wineJITPoolMiB") private var wineJITPoolMiB = 0
    @AppStorage(HardwareInput.enabledKey) private var keyboardMouseEnabled = true
    @AppStorage(HardwareInput.mouseSensitivityKey) private var mouseSensitivity = 1.0
    @AppStorage(HardwareInput.stickMouseKey) private var rightStickMouse = false
    @AppStorage(BackgroundDownloads.continuedKey) private var continueDownloadsInBackground = true
    @AppStorage(BackgroundDownloads.notificationsKey) private var downloadNotifications = true
    @AppStorage(SystemCoordinator.jitMethodKey) private var jitMethod = "stikdebug"
    @State private var winePoolChangeRequiresRestart = false
    @AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false
    @StateObject private var updater = UpdateChecker()
    @State private var isSteamSignInPresented = false
    @ObservedObject private var gogLibrary = GOGLibraryModel.shared
    @ObservedObject private var epicLibrary = EpicLibrary.shared
    @ObservedObject private var externalDrives = ExternalDrives.shared
    @State private var isGOGSignInPresented = false
    @State private var isEpicSignInPresented = false
    @State private var isPairingImporterPresented = false
    @State private var jitDiagnosticsCopied = false
    @State private var steamComponentsStatus: String?
    @State private var steamComponentsBusy = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack {
            Form {
                overviewSection

                Section(tr("Accounts")) {
                    NavigationLink { steamPage } label: {
                        SettingsRow(icon: "gamecontroller.fill", color: .blue, title: "Steam",
                                    value: coordinator.isSteamConnected ? (SteamSignIn.accountName ?? tr("Connected")) : tr("Not connected"))
                    }
                    NavigationLink { gogPage } label: {
                        SettingsRow(icon: "shippingbox.fill", color: .purple, title: "GOG",
                                    value: gogLibrary.isSignedIn ? (gogLibrary.username ?? tr("Connected")) : tr("Not connected"))
                    }
                    NavigationLink { epicPage } label: {
                        SettingsRow(icon: "e.square.fill", color: .gray, title: "Epic Games",
                                    value: epicLibrary.signedIn ? (epicLibrary.accountName ?? tr("Connected")) : tr("Not connected"))
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
                        SettingsRow(icon: "keyboard.fill", color: .indigo, title: tr("Controls"),
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

                Section(tr("Apps")) {
                    NavigationLink { LiveContainerSettingsView(coordinator: coordinator) } label: {
                        SettingsRow(icon: "square.stack.3d.up.fill", color: .cyan, title: "LiveContainer")
                    }
                }

                Section(tr("General")) {
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
            HardwareInput.shared.start()
            await updater.check()
        }
        .onChange(of: wineJITPoolMiB) { _, selected in
            winePoolChangeRequiresRestart = !coordinator.updateWineJITPoolPreference(selected)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refreshJITStatus() }
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
                    SettingsStatusPill(text: tr(MadeiraBundleIdentity.isNative ? "Madeira-native" : "Interface-only"),
                               color: MadeiraBundleIdentity.isNative ? .green : .orange)
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
                if MadeiraDock.bundled && !MadeiraDock.clientInstalled {
                    Button {
                        downloadSteamComponents()
                    } label: {
                        HStack {
                            Text(tr("Download Steam's components"))
                            if steamComponentsBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(steamComponentsBusy)
                }
                if let steamComponentsStatus {
                    Text(steamComponentsStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(tr("Steam client"))
            } footer: {
                Text(tr("Games with Steam DRM start through Valve's own Windows client (Madeira Dock): turn on \"Start through the Steam client\" in the game's settings. The components (about 72 MB) come from Valve's update server and are checked against pinned checksums."))
            }
        }
        .navigationTitle("Steam")
    }

    private func downloadSteamComponents() {
        steamComponentsBusy = true
        steamComponentsStatus = nil
        Task {
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { message in
                    await MainActor.run { steamComponentsStatus = message }
                }
            } catch {
                steamComponentsStatus = error.localizedDescription
            }
            steamComponentsBusy = false
        }
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
            } footer: {
                Text(tr("Games download from Epic's servers and start with a one-use Epic sign-in code. The Epic launcher is not installed."))
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
                LabeledContent(tr("Pairing file"), value: coordinator.hasPairingFile ? tr("Imported") : tr("Missing"))
                Button(coordinator.hasPairingFile ? tr("Replace pairing file") : tr("Import pairing file")) {
                    isPairingImporterPresented = true
                }
            } header: {
                Text(tr("Activation"))
            } footer: {
                Text(tr("Built-in: iDeck's own helper attaches the debugger through LocalDevVPN with your pairing file, without opening another app. StikDebug: iDeck asks StikDebug to attach."))
            }
            Section {
                Picker(selection: $wineJITPoolMiB) {
                    Text(tr("Automatic")).tag(0)
                    ForEach([64, 96, 128, 192, 256, 384], id: \.self) { size in
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
            } footer: {
                Text(tr("Wine JIT pool size is selected before allocation and cannot change while mapped."))
            }
        }
        .navigationTitle(tr("JIT & Debugging"))
    }

    private var shouldShowJITDiagnostics: Bool {
        // The snapshot is a read-only try-lock probe; reading it does not
        // allocate executable memory or trigger the StikDebug BRK handler.
        let snapshot = ideck_jit_snapshot()
        return !coordinator.isJITEnabled ||
               (!coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared) ||
               snapshot.wine_failure_stage != 0 ||
               snapshot.wine_failure_rx_detail != 0 ||
               snapshot.wine_failure_mach_code != 0
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
                Text(tr("JIT permission does not guarantee that FEX is ready."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text(tr("StikDebug requires pairing, LocalDevVPN, and a debug-signable iDeck. Opening StikDebug does not prove FEX JIT is ready."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if shouldShowJITDiagnostics {
            Button {
                copyJITDiagnostics()
            } label: {
                HStack {
                    Label(tr("Copy JIT diagnostics"), systemImage: "doc.on.doc")
                    Spacer()
                    if jitDiagnosticsCopied {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .accessibilityLabel(tr("Copy JIT diagnostics"))
        }
    }

    private func copyJITDiagnostics() {
        let snapshot = ideck_jit_snapshot()
        let jitPermission = ideck_process_has_jit_permission()
        let wineValidated = snapshot.wine_pool_prepared &&
            snapshot.rx_executable && snapshot.rw_writable
        let values = [
            "iDeck Madeira Stage 7 — on-device JIT snapshot",
            "iPadOS version: \(UIDevice.current.systemVersion)",
            "App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            "JIT method: \(jitMethod)",
            "CS_DEBUGGED permission: \(jitPermission)",
            "Live debugger attached: \(snapshot.debugger_attached)",
            "FEX initialized: \(snapshot.fex_initialized)",
            "FEX initialization in progress: \(snapshot.fex_state_busy)",
            "Wine pool prepared: \(snapshot.wine_pool_prepared)",
            "Wine pool inspection busy: \(snapshot.wine_state_busy)",
            "Wine RX executable and non-writable: \(snapshot.rx_executable)",
            "Wine RW writable and non-executable: \(snapshot.rw_writable)",
            "Wine pool mapping validated: \(wineValidated)",
            "Wine pool size MiB: \(snapshot.wine_pool_mib)",
            "Wine failure stage: \(snapshot.wine_failure_stage)",
            "Wine RX failure detail: \(snapshot.wine_failure_rx_detail)",
            "Wine Mach error: \(snapshot.wine_failure_mach_code)",
            "JIT guest code execution: NOT TESTED by this snapshot",
            "StikDebug BRK handler compatibility: NOT PROVEN by debugger attachment"
        ]
        UIPasteboard.general.string = values.joined(separator: "\n")
        jitDiagnosticsCopied = true
    }

    // MARK: Controls

    private var controlsPage: some View {
        Form {
            settingsSection(title: tr("Controller")) {
                Picker(tr("Windows controller API"), selection: $wineControllerAPI) {
                    ForEach(["XInput", "XInput + DirectInput", "HID", "DualSense HID", "Generic HID"], id: \.self) { api in
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
                toggleRow(title: tr("Right stick controls mouse"), isOn: $rightStickMouse)
            }
            Section {
                toggleRow(title: tr("Keyboard & mouse in games"), isOn: $keyboardMouseEnabled)
                LabeledContent(tr("Keyboard"), value: hardwareInput.keyboardName ?? tr("Not connected"))
                LabeledContent(tr("Mouse"), value: hardwareInput.mouseName ?? tr("Not connected"))
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(tr("Mouse sensitivity"), value: String(format: "%.2fx", mouseSensitivity))
                    Slider(value: $mouseSensitivity, in: 0.25...3.0, step: 0.05)
                }
            } header: {
                Text(tr("Keyboard & mouse"))
            } footer: {
                Text(tr("Physical keys and raw mouse movement go to the game while it is on screen. With the right stick as mouse, R1 clicks and L1 right-clicks."))
            }
        }
        .navigationTitle(tr("Controls"))
    }

    // MARK: Graphics

    private var graphicsPage: some View {
        Form {
            settingsSection(title: tr("Graphics & Performance")) {
                toggleRow(title: tr("MetalFX Upscaling"), isOn: $coordinator.isMetalFXEnabled)
                toggleRow(title: tr("Hold Display at Maximum Rate"), isOn: $coordinator.isMaxRefreshRateEnabled)
                toggleRow(title: tr("Show FPS, CPU & GPU overlay"), isOn: $showGamePerformanceOverlay)
                toggleRow(title: tr("D3DMetal Rendering"), isOn: $coordinator.isD3DMetalEnabled)
            }
            Section {
            } footer: {
                Text(tr("Graphics changes apply when you launch the next game."))
            }
        }
        .navigationTitle(tr("Graphics & Performance"))
    }

    // MARK: Storage

    private var storagePage: some View {
        Form {
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
            } header: {
                Text(tr("Downloads"))
            } footer: {
                Text(tr("iOS shows the download's progress while iDeck is in the background. If iOS stops it, the download pauses and continues when you return."))
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
                LabeledContent(tr("Graphics backend"), value: (runtime["graphicsBackend"] as? String ?? "none").uppercased())
                LabeledContent("WoW64", value: tr((runtime["wow64Enabled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent("Wine Mono", value: tr((runtime["wineMonoBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent("Metal Shader Converter",
                               value: tr((runtime["metalShaderConverterBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent(tr("Madeira Dock"), value: tr(MadeiraDock.bundled ? "Bundled" : "Not bundled"))
                if runtime["wineMonoBundled"] as? Bool != true {
                    Text(tr("Wine Mono is not included. Run iOS Build with Require Madeira runtime and Wine Mono enabled to create a different signed IPA."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !MadeiraBundleIdentity.isNative {
                    Text(tr(MadeiraBundleIdentity.missingRuntimeMessage))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(tr("Windows runtime"))
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
            // No in-app iDeck update action: users install signed IPAs through
            // their chosen installer. The version list remains read-only.
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
