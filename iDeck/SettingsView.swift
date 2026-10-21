import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var isImportingPairingFile = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("JIT & Debugging")) {
                    Button(action: {
                        coordinator.activateJITManually()
                    }) {
                        Text("Activate JIT")
                            .foregroundColor(.blue)
                    }
                    
                    Button(action: {
                        isImportingPairingFile = true
                    }) {
                        Text("Import Pairing File")
                            .foregroundColor(.blue)
                    }
                    
                    Toggle("JIT Pool", isOn: $coordinator.isJITPoolEnabled)
                }
                
                Section(header: Text("Graphics & Performance")) {
                    Toggle("MetalFX", isOn: $coordinator.isMetalFXEnabled)
                    Toggle("Hold Display at Maximum Rate", isOn: $coordinator.isMaxRefreshRateEnabled)
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .fileImporter(
                isPresented: $isImportingPairingFile,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        coordinator.importPairingFile(at: url)
                    }
                case .failure:
                    break
                }
            }
        }
    }
}
