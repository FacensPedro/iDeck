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
                    }
                    .padding()
                }
                Spacer()
            }
            
            VStack(spacing: 24) {
                Text("iDeck System")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                HStack {
                    StatusIndicator(isActive: coordinator.isJITEnabled, label: "JIT Active")
                    StatusIndicator(isActive: coordinator.isContainerReady, label: "Container Ready")
                    StatusIndicator(isActive: inputManager.isControllerConnected, label: "Controller")
                }
                
                Text(coordinator.currentStatus)
                    .foregroundColor(.gray)
                
                Toggle("Performance HUD", isOn: $coordinator.isHUDEnabled)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                    .foregroundColor(.white)
                
                Button(action: {
                    coordinator.initializeSystem()
                }) {
                    Text("Initialize Core Systems")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(coordinator.isJITEnabled && coordinator.isContainerReady)
                
                Button(action: {
                    coordinator.launchSteam()
                }) {
                    Text("Install & Run Steam")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(coordinator.isJITEnabled && coordinator.isContainerReady ? Color.orange : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!coordinator.isJITEnabled || !coordinator.isContainerReady)
                
                Button(action: {
                    isDocumentPickerPresented = true
                }) {
                    Text("Install and Run .exe")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(coordinator.isJITEnabled && coordinator.isContainerReady ? Color.green : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!coordinator.isJITEnabled || !coordinator.isContainerReady)
            }
            .padding()
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

struct StatusIndicator: View {
    let isActive: Bool
    let label: String
    
    var body: some View {
        HStack {
            Circle()
                .fill(isActive ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(8)
        .background(Color.gray.opacity(0.3))
        .cornerRadius(8)
    }
}
