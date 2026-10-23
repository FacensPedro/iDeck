import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var inputManager = InputManager.shared
    @AppStorage("controllerLeftSensitivity") private var controllerLeftSensitivity = 1.0
    @AppStorage("controllerRightSensitivity") private var controllerRightSensitivity = 1.0
    @AppStorage("controllerDeadzone") private var controllerDeadzone = 0.10
    @StateObject private var updater = UpdateChecker()
    @State private var isSteamSignInPresented = false
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
                            
                            Text(tr("JIT is detected automatically. To activate it, enable JIT for iDeck in StikDebug, then return here."))
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding()
                            actionButton(title: tr("Refresh JIT status"), icon: "arrow.clockwise") {
                                coordinator.refreshJITStatus()
                            }
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
                                Text(tr("Connected controller")).foregroundColor(.white)
                                Spacer()
                                Text(inputManager.isControllerConnected ? inputManager.controllerName : tr("Not connected"))
                                    .font(.caption).foregroundColor(inputManager.isControllerConnected ? .green : .gray)
                                    .multilineTextAlignment(.trailing)
                            }.padding()
                            sensitivityRow(title: tr("Left stick sensitivity"), value: $controllerLeftSensitivity)
                            sensitivityRow(title: tr("Right stick sensitivity"), value: $controllerRightSensitivity)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(tr("Stick dead zone")).foregroundColor(.white); Spacer(); Text(String(format: "%.2f", controllerDeadzone)).foregroundColor(.gray) }
                                Slider(value: $controllerDeadzone, in: 0...0.35, step: 0.01).tint(.blue)
                            }.padding()
                        }

                        settingsSection(title: tr("Graphics & Performance")) {
                            toggleRow(title: tr("MetalFX Upscaling"), isOn: $coordinator.isMetalFXEnabled)
                            toggleRow(title: tr("Hold Display at Maximum Rate"), isOn: $coordinator.isMaxRefreshRateEnabled)
                            toggleRow(title: tr("DXVK HUD"), isOn: $coordinator.isHUDEnabled)
                            toggleRow(title: tr("D3DMetal Rendering"), isOn: $coordinator.isD3DMetalEnabled)
                        }
                        
                        settingsSection(title: tr("Updates")) {
                            updatesContent
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
        .task { await updater.check() }
        .preferredColorScheme(.dark)
    }
    
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.isJITEnabled ? tr("JIT detected") : tr("JIT not detected"))
                .font(.footnote)
                .foregroundColor(coordinator.isJITEnabled ? .green : .white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .padding(.bottom, 2)
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
        
        if let update = updater.availableIDeckUpdate {
            actionButton(title: tr("Install iDeck %@", update.latest ?? ""), icon: "arrow.down.circle.fill") {
                updater.installIDeckUpdate()
            }
        }
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
