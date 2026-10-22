import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var isImportingPairingFile = false
    @State private var isImportingDDI = false
    @StateObject private var updater = UpdateChecker()
    @AppStorage("jitServerURL") private var jitServerURL = ""
    @AppStorage("jitServerToken") private var jitServerToken = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        settingsSection(title: "JIT & Debugging") {
                            statusRow
                            
                            actionButton(title: "Activate JIT", icon: "bolt.fill") {
                                coordinator.activateJITManually()
                            }
                            
                            actionButton(title: "Import Pairing File", icon: "lock.shield.fill") {
                                isImportingPairingFile = true
                            }
                            
                            actionButton(title: "Mount Developer Disk Image", icon: "externaldrive.fill") {
                                isImportingDDI = true
                            }
                            
                            jitServerFields
                            
                            toggleRow(title: "JIT Pool", isOn: $coordinator.isJITPoolEnabled)
                            toggleRow(title: "VPN JIT Trigger", isOn: $coordinator.isVPNJITEnabled)
                        }
                        
                        settingsSection(title: "Graphics & Performance") {
                            toggleRow(title: "MetalFX Upscaling", isOn: $coordinator.isMetalFXEnabled)
                            toggleRow(title: "Hold Display at Maximum Rate", isOn: $coordinator.isMaxRefreshRateEnabled)
                            toggleRow(title: "DXVK HUD", isOn: $coordinator.isHUDEnabled)
                            toggleRow(title: "D3DMetal Rendering", isOn: $coordinator.isD3DMetalEnabled)
                        }
                        
                        settingsSection(title: "Updates") {
                            updatesContent
                        }
                        
                        settingsSection(title: "LiveContainer") {
                            toggleRow(title: "Inject Guest Hooks", isOn: $coordinator.isGuestHooksEnabled)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .fileImporter(
                isPresented: $isImportingPairingFile,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    coordinator.importPairingFile(at: url)
                }
            }
            .fileImporter(
                isPresented: $isImportingDDI,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    coordinator.mountDDI(urls: urls)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { coordinator.refreshPairingFileState() }
        .preferredColorScheme(.dark)
    }
    
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.currentStatus)
                .font(.footnote)
                .foregroundColor(.white)
            Text(coordinator.hasPairingFile ? "Pairing file: imported" : "Pairing file: none")
                .font(.caption)
                .foregroundColor(coordinator.hasPairingFile ? .green : .gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .padding(.bottom, 2)
    }
    
    private var jitServerFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JIT helper server")
                .font(.caption).fontWeight(.bold).foregroundColor(.gray)
            TextField("http://192.168.1.10:54321", text: $jitServerURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
            SecureField("Token (JIT_SERVER_TOKEN)", text: $jitServerToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
            Text("Run server_jit/server.py on a computer connected to this device, then enter its address here. The pairing file stays on the device and is not sent to the server.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .foregroundColor(.white)
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
                        .foregroundColor(status.upstreamChanged ? .orange : .gray)
                }
            }
            if let message = updater.message {
                Text(message).font(.caption).foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .padding(.bottom, 2)
        
        actionButton(title: updater.isChecking ? "Checking..." : "Check for Updates", icon: "arrow.triangle.2.circlepath") {
            Task { await updater.check() }
        }
        .disabled(updater.isChecking)
        
        if let update = updater.availableIDeckUpdate {
            actionButton(title: "Install iDeck \(update.latest ?? "")", icon: "arrow.down.circle.fill") {
                updater.installIDeckUpdate()
            }
        }
    }
    
    private func versionText(for status: ProjectStatus) -> String {
        if status.project.id == UpdateChecker.ideck.id {
            let latest = status.latest ?? "no release yet"
            return "v\(updater.currentVersion) · latest \(latest)"
        }
        guard let latest = status.latest else { return status.error == nil ? "-" : "unavailable" }
        if let pinned = status.project.pinnedVersion {
            return status.upstreamChanged ? "\(pinned) → \(latest)" : "\(latest)"
        }
        return "latest \(latest)"
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
    
    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .padding()
            .foregroundColor(.white)
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
            .padding(.bottom, 2)
            .tint(.blue)
    }
}
