import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var isImportingPairingFile = false
    @State private var isImportingDDI = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        settingsSection(title: "JIT & Debugging") {
                            actionButton(title: "Activate JIT", icon: "bolt.fill") {
                                coordinator.activateJITManually()
                            }
                            
                            actionButton(title: "Import Pairing File", icon: "lock.shield.fill") {
                                isImportingPairingFile = true
                            }
                            
                            actionButton(title: "Mount Developer Disk Image", icon: "externaldrive.fill") {
                                isImportingDDI = true
                            }
                            
                            toggleRow(title: "JIT Pool", isOn: $coordinator.isJITPoolEnabled)
                            toggleRow(title: "VPN JIT Trigger", isOn: $coordinator.isVPNJITEnabled)
                        }
                        
                        settingsSection(title: "Graphics & Performance") {
                            toggleRow(title: "MetalFX Upscaling", isOn: $coordinator.isMetalFXEnabled)
                            toggleRow(title: "Hold Display at Maximum Rate", isOn: $coordinator.isMaxRefreshRateEnabled)
                            toggleRow(title: "DXVK HUD", isOn: $coordinator.isHUDEnabled)
                            toggleRow(title: "D3DMetal Rendering", isOn: $coordinator.isD3DMetalEnabled)
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
        .preferredColorScheme(.dark)
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
