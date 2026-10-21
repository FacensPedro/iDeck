import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @StateObject private var inputManager = InputManager()
    @State private var isDocumentPickerPresented = false
    @State private var isSettingsPresented = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        isSettingsPresented = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                Spacer()
            }
            
            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Text("iDeck")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(coordinator.currentStatus)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                HStack(spacing: 16) {
                    StatusPill(isActive: coordinator.isJITEnabled, label: "JIT")
                    StatusPill(isActive: coordinator.isContainerReady, label: "Container")
                    StatusPill(isActive: inputManager.isControllerConnected, label: "Gamepad")
                }
                
                VStack(spacing: 16) {
                    Button(action: {
                        coordinator.startLiveContainer()
                    }) {
                        HStack {
                            Image(systemName: "cube.box.fill")
                            Text("Start LiveContainer")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    
                    Button(action: {
                        coordinator.startWindows()
                    }) {
                        HStack {
                            Image(systemName: "window.casement")
                            Text("Start Windows")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 32)
                
                VStack(spacing: 16) {
                    Button(action: {
                        coordinator.launchSteam()
                    }) {
                        Text("Install & Run Steam")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    
                    Button(action: {
                        isDocumentPickerPresented = true
                    }) {
                        Text("Run Executable (.exe)")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 32)
                .opacity((coordinator.isJITEnabled && coordinator.isContainerReady) ? 1.0 : 0.5)
                .disabled(!coordinator.isJITEnabled || !coordinator.isContainerReady)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(coordinator: coordinator)
        }
        .fileImporter(
            isPresented: $isDocumentPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "exe")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    coordinator.launchWindowsExecutable(at: url)
                }
            case .failure:
                break
            }
        }
    }
}

struct StatusPill: View {
    let isActive: Bool
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
        .cornerRadius(16)
    }
}
