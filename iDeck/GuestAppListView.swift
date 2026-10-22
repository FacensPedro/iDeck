import SwiftUI
import UniformTypeIdentifiers

struct GuestAppListView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @StateObject private var appManager = AppManager()
    @State private var isPickerPresented = false
    @State private var installMessage: String?
    @State private var isShowingInstallResult = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue // re-renders on change
    
    var body: some View {
        VStack {
            HStack {
                Text(tr("LiveContainer Apps"))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    isPickerPresented = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            
            if appManager.installedApps.isEmpty {
                Text(tr("No apps installed. Tap + to install an .ipa"))
                    .foregroundColor(.gray)
                    .padding()
            } else {
                List(appManager.installedApps, id: \.self) { appURL in
                    Button(action: {
                        coordinator.launchGuestApp(at: appURL)
                    }) {
                        HStack {
                            Image(systemName: "app.fill")
                                .foregroundColor(.white)
                            Text(appURL.lastPathComponent.replacingOccurrences(of: ".app", with: ""))
                                .foregroundColor(.white)
                        }
                    }
                    .listRowBackground(Color(red: 0.15, green: 0.15, blue: 0.15))
                }
                .scrollContentBackground(.hidden)
            }
        }
        .alert(tr("IPA installation"), isPresented: $isShowingInstallResult) {
            Button(tr("OK"), role: .cancel) { }
        } message: {
            Text(installMessage ?? tr("Unknown installation result"))
        }
        .onAppear { appManager.refreshInstalledApps() }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "ipa")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    appManager.installIPA(from: url) { success in
                        installMessage = success ? tr("IPA installed. Select the app to launch it.") : tr("Installation failed. Verify that the IPA contains Payload/*.app and is a valid ZIP archive.")
                        isShowingInstallResult = true
                    }
                }
            case .failure(let error):
                installMessage = error.localizedDescription
                isShowingInstallResult = true
            }
        }
    }
}
