import SwiftUI
import UniformTypeIdentifiers

struct GuestAppListView: View {
    @ObservedObject var coordinator: SystemCoordinator
    @StateObject private var appManager = AppManager()
    @State private var isPickerPresented = false
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
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "ipa")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    appManager.installIPA(from: url) { _ in }
                }
            case .failure:
                break
            }
        }
    }
}
