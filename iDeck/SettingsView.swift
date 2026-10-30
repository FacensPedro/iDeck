import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var inputManager = InputManager.shared
    @AppStorage("controllerLeftSensitivity") private var controllerLeftSensitivity = 1.0
    @AppStorage("controllerRightSensitivity") private var controllerRightSensitivity = 1.0
    @AppStorage("controllerDeadzone") private var controllerDeadzone = 0.10
    @AppStorage("wineControllerAPI") private var wineControllerAPI = "XInput"
    @AppStorage("wineJITPoolMiB") private var wineJITPoolMiB = 0
    @State private var winePoolChangeRequiresRestart = false
    @AppStorage("showGamePerformanceOverlay") private var showGamePerformanceOverlay = false
    @StateObject private var updater = UpdateChecker()
    @State private var isSteamSignInPresented = false
    @State private var jitDiagnosticsCopied = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        settingsSection(title: tr("Language")) {
                            languagePicker
                        }
                        
                        settingsSection(title: tr("JIT & Debugging")) {
                            statusRow
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(tr("Wine JIT pool"))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Picker(tr("Wine JIT pool"), selection: $wineJITPoolMiB) {
                                        Text(tr("Automatic")).tag(0)
                                        ForEach([64, 96, 128, 192, 256, 384], id: \.self) { size in
                                            Text("\(size) MiB").tag(size)
                                        }
                                    }
                                    .tint(.white)
                                }
                                Text(tr("Wine JIT pool size is selected before allocation and cannot change while mapped."))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                if winePoolChangeRequiresRestart {
                                    Text(tr("Restart iDeck before the new Wine JIT pool size can take effect."))
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(16)
                        }
                        
                        settingsSection(title: tr("Steam")) {
                            HStack(alignment: .top) {
                                Text(tr("Steam account"))
                                    .foregroundColor(.white)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(coordinator.isSteamConnected ? tr("Connected") : tr("Not connected"))
                                        .font(.caption)
                                        .foregroundColor(coordinator.isSteamConnected ? .green : .gray)
                                    if coordinator.isSteamConnected, let account = SteamSignIn.accountName {
                                        Text(account)
                                            .font(.caption)
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .padding()
                            if coordinator.isSteamConnected {
                                actionButton(title: tr("Disconnect Steam"), icon: "rectangle.portrait.and.arrow.right") {
                                    coordinator.disconnectSteamAccount()
                                }
                            } else {
                                actionButton(title: tr("Connect Steam"), icon: "link") {
                                    isSteamSignInPresented = true
                                }
                            }
                        }

                        settingsSection(title: tr("Controller")) {
                            HStack {
                                Text(tr("Windows controller API")).foregroundColor(.white)
                                Spacer()
                                Picker(tr("Windows controller API"), selection: $wineControllerAPI) {
                                    ForEach(["XInput", "XInput + DirectInput", "HID", "DualSense HID", "Generic HID"], id: \.self) { api in
                                        Text(tr(api)).tag(api)
                                    }
                                }
                                .tint(.white)
                            }.padding(.horizontal, 16)
                            HStack {
                                Text(tr("Connected controller")).foregroundColor(.white)
                                Spacer()
                                Text(inputManager.isControllerConnected ? inputManager.controllerName : tr("Not connected"))
                                    .font(.caption).foregroundColor(inputManager.isControllerConnected ? .green : .gray)
                                    .multilineTextAlignment(.trailing)
                            }.padding()
                            if inputManager.isControllerConnected {
                                sensitivityRow(title: tr("Left stick sensitivity"), value: $controllerLeftSensitivity)
                                sensitivityRow(title: tr("Right stick sensitivity"), value: $controllerRightSensitivity)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(tr("Stick dead zone")).foregroundColor(.white)
                                        Spacer()
                                        Text(String(format: "%.2f", controllerDeadzone)).foregroundColor(.gray)
                                    }
                                    Slider(value: $controllerDeadzone, in: 0...0.35, step: 0.01).tint(.blue)
                                }.padding()
                            }
                        }

                        settingsSection(title: tr("Graphics & Performance")) {
                            toggleRow(title: tr("MetalFX Upscaling"), isOn: $coordinator.isMetalFXEnabled)
                            toggleRow(title: tr("Hold Display at Maximum Rate"), isOn: $coordinator.isMaxRefreshRateEnabled)
                            toggleRow(title: tr("Show FPS, CPU & GPU overlay"), isOn: $showGamePerformanceOverlay)
                            toggleRow(title: tr("D3DMetal Rendering"), isOn: $coordinator.isD3DMetalEnabled)
                            Text(tr("Graphics changes apply when you launch the next game."))
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                        
                        settingsSection(title: tr("Updates")) {
                            updatesContent
                        }
                        
                        settingsSection(title: tr("Windows runtime")) {
                            let runtime = MadeiraBundleIdentity.profile
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(tr("IPA runtime"))
                                    Spacer()
                                    Text(tr(MadeiraBundleIdentity.isNative
                                        ? "Madeira-native" : "Interface-only"))
                                        .foregroundColor(MadeiraBundleIdentity.isNative ? .green : .orange)
                                }
                                HStack {
                                    Text(tr("Graphics backend"))
                                    Spacer()
                                    Text((runtime["graphicsBackend"] as? String ?? "none").uppercased())
                                }
                                HStack {
                                    Text("WoW64")
                                    Spacer()
                                    Text(tr((runtime["wow64Enabled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                                }
                                HStack {
                                    Text("Wine Mono")
                                    Spacer()
                                    Text(tr((runtime["wineMonoBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                                }
                                if runtime["wineMonoBundled"] as? Bool != true {
                                    Text(tr("Wine Mono is not included. Run iOS Build with Require Madeira runtime and Wine Mono enabled to create a different signed IPA."))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack {
                                    Text("Metal Shader Converter")
                                    Spacer()
                                    Text(tr((runtime["metalShaderConverterBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                                }
                                if !MadeiraBundleIdentity.isNative {
                                    Text(tr(MadeiraBundleIdentity.missingRuntimeMessage))
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(16)
                        }

                        settingsSection(title: tr("LiveContainer")) {
                            toggleRow(title: tr("Inject Guest Hooks"), isOn: $coordinator.isGuestHooksEnabled)
                        }
                    }
                    .padding(horizontalSizeClass == .compact ? 14 : 28)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(tr("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(tr("Done")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $isSteamSignInPresented) {
            SteamSignInView()
        }
        .task {
            inputManager.refreshControllers()
            coordinator.refreshJITStatus()
            await updater.check()
        }
        .onChange(of: wineJITPoolMiB) { _, selected in
            winePoolChangeRequiresRestart = !coordinator.updateWineJITPoolPreference(selected)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshJITStatus()
            }
        }
        .preferredColorScheme(.dark)
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

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: coordinator.isJITEnabled ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.title3)
                    .foregroundColor(coordinator.isJITEnabled ? .green : .orange)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.isJITEnabled ? tr("JIT detected") : tr("JIT not detected"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(tr("JIT permission does not guarantee that FEX is ready."))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if shouldShowJITDiagnostics {
                Button {
                    copyJITDiagnostics()
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text(tr("Copy JIT diagnostics"))
                        Spacer()
                        if jitDiagnosticsCopied {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Copy JIT diagnostics"))
                if jitDiagnosticsCopied {
                    Text(tr("JIT diagnostics copied to clipboard"))
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            if coordinator.isJITEnabled {
                HStack {
                    Text(tr("Debugger connection")).foregroundColor(.white)
                    Spacer()
                    Text(coordinator.isStikDebugAttached ? tr("Attached") : tr("Detached"))
                        .foregroundColor(coordinator.isStikDebugAttached ? .green : .orange)
                }
                .font(.caption)
            }
            if coordinator.isJITEnabled && !coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared {
                Text(tr("JIT permission is active, but StikDebug's debugger script is not connected. Use the button below to reconnect before starting Wine."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !coordinator.isJITEnabled || (!coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared) {
                Button {
                    coordinator.requestStikDebugJIT()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(tr(coordinator.isJITEnabled ? "Reconnect JIT debugger" : "Enable JIT"))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .background(Color(red: 0.12, green: 0.34, blue: 0.70), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr(coordinator.isJITEnabled ? "Reconnect JIT debugger" : "Enable JIT"))
                Text(tr("StikDebug requires pairing, LocalDevVPN, and a debug-signable iDeck. Opening StikDebug does not prove FEX JIT is ready."))
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(red: 0.15, green: 0.15, blue: 0.15), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 2)
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

    private var languagePicker: some View {
        HStack {
            Text(tr("Language"))
                .foregroundColor(.white)
            Spacer()
            Picker(tr("Language"), selection: $appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .tint(.blue)
        }
        .padding()
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .padding(.bottom, 2)
    }
    
    @ViewBuilder
    private var updatesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(updater.statuses) { status in
                HStack {
                    Text(status.project.name)
                        .foregroundColor(.white)
                    Spacer()
                    Text(versionText(for: status))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .padding(.bottom, 2)
        
        actionButton(title: updater.isChecking ? tr("Checking...") : tr("Check for Updates"), icon: "arrow.triangle.2.circlepath") {
            Task { await updater.check() }
        }
        .disabled(updater.isChecking)
        
        // No in-app iDeck update action: users install signed IPAs through
        // their chosen installer. The version list remains read-only.
    }
    
    /// iDeck shows the installed version; the other projects show the newest release that has an IPA.
    private func versionText(for status: ProjectStatus) -> String {
        if status.project.id == UpdateChecker.ideck.id {
            return "v\(updater.currentVersion)"
        }
        if !updater.hasChecked { return "-" }
        if status.failed { return tr("unavailable") }
        guard let latest = status.latest else { return tr("no IPA release") }
        return latest
    }
    
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.gray)
                .padding(.horizontal, 4)
            
            VStack(spacing: 0) {
                content()
            }
            .background(Color(red: 0.1, green: 0.1, blue: 0.1))
            .cornerRadius(12)
        }
    }
    
    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding()
            .foregroundColor(.white)
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        }
        .padding(.bottom, 2)
    }
    
    private func sensitivityRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).foregroundColor(.white); Spacer(); Text(String(format: "%.2fx", value.wrappedValue)).foregroundColor(.gray) }
            Slider(value: value, in: 0.25...2.0, step: 0.05).tint(.blue)
        }
        .padding()
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .padding(.bottom, 2)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .padding()
            .foregroundColor(.white)
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
            .padding(.bottom, 2)
            .tint(.blue)
    }
}
