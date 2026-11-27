// ExternalDrivesSettingsView.swift
// Split from ExternalDrives.swift (iDeck 3.0 architecture).

import Foundation
import SwiftUI

struct ExternalDrivesSettingsView: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var isPickerPresented = false

    var body: some View {
        Form {
            Section {
                if drives.folders.isEmpty {
                    Text(tr("No external folders"))
                        .foregroundStyle(.secondary)
                }
                ForEach(drives.folders) { folder in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("\(folder.letter.uppercased()):  \(folder.name)", systemImage: "externaldrive")
                            Spacer()
                            Text(drives.mounted[folder.id] != nil ? tr("Connected") : tr("Not connected"))
                                .font(.caption)
                                .foregroundStyle(drives.mounted[folder.id] != nil ? .green : .secondary)
                        }
                        Toggle(tr("Install new games here"), isOn: Binding(
                            get: { folder.receivesInstalls },
                            set: { drives.setReceivesInstalls(folder, $0) }))
                            .font(.subheadline)
                    }
                    .swipeActions {
                        Button(tr("Remove"), role: .destructive) { drives.remove(folder) }
                    }
                }
                Button {
                    isPickerPresented = true
                } label: {
                    Label(tr("Add folder"), systemImage: "plus")
                }
            } footer: {
                Text(tr("Folders appear in Windows as drives and under C:\\External. Removing a folder here keeps its files."))
            }
            if let error = drives.lastError {
                Section {
                    Text(error).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(tr("External drives"))
        .fileImporter(isPresented: $isPickerPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { drives.add(url) }
        }
    }
}
