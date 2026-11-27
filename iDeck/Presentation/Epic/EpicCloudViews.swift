// EpicCloudViews.swift
// Split from EpicCloud.swift (iDeck 3.0 architecture).

import SwiftUI

/// A game's Epic Cloud saves, on its Game details page below the Epic Games section.
struct EpicCloudSection: View {
    let appName: String
    @ObservedObject private var cloud = EpicCloud.shared
    @ObservedObject private var setting = EpicCloudSetting.shared
    @ObservedObject private var installer = EpicLibrary.shared
    @State private var confirmCloud = false
    @State private var confirmDevice = false

    private static func when(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? tr("unknown date") }
    private static func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file) }
    private static func files(_ n: Int) -> String { (n == 1 ? tr("1 file") : tr("%d files", n)) }

    var body: some View {
        let state = cloud.state(appName)
        if setting.on, installer.installed[appName] != nil, state.phase != .unsupported {
            Section {
                if !installer.signedIn {
                    Text(tr("Sign in to Epic Games to sync saves.")).foregroundStyle(.secondary)
                } else {
                    if installer.sessionRunning {
                        Text(tr("Close the game to sync saves.")).foregroundStyle(.secondary)
                    }
                    rows(state).disabled(installer.sessionRunning || cloud.isBusy)
                }
            } header: {
                Text(tr("Epic Cloud saves"))
            }
            .task { await cloud.check(appName, automatic: true) }
        }
    }

    @ViewBuilder private func rows(_ state: EpicCloud.State) -> some View {
        switch state.phase {
        case .idle, .checking:
            HStack(spacing: 10) { ProgressView(); Text(tr("Checking Epic's cloud…")).foregroundStyle(.secondary) }
        case .downloading:
            HStack(spacing: 10) { ProgressView(); Text(tr("Downloading saves…")).foregroundStyle(.secondary) }
        case .uploading:
            HStack(spacing: 10) { ProgressView(); Text(tr("Uploading saves…")).foregroundStyle(.secondary) }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.orange)
            Button(tr("Try again")) { Task { await cloud.check(appName, automatic: false) } }
        case .unsupported:
            EmptyView()
        case .ready:
            ready(state)
        }
    }

    @ViewBuilder private func ready(_ state: EpicCloud.State) -> some View {
        switch state.verdict {
        case .conflict:
            Label(tr("The saves on this device and in Epic's cloud differ"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Epic's cloud: %@", "\(Self.when(state.cloudDate)) · \(Self.files(state.cloudFiles)) · \(Self.size(state.cloudBytes))"))
                Text(tr("This device: %@", "\(Self.when(state.deviceDate)) · \(Self.files(state.deviceFiles)) · \(Self.size(state.deviceBytes))"))
            }.font(.caption).foregroundStyle(.secondary)
            Text(tr("Nothing is changed until you choose which to keep.")).font(.caption).foregroundStyle(.secondary)
            Button(tr("Keep Epic's saves…")) { confirmCloud = true }
                .confirmationDialog(tr("Use Epic's saves on this device? The files they replace are copied to Files › iDeck › Epic Cloud Backups first."),
                                    isPresented: $confirmCloud, titleVisibility: .visible) {
                    Button(tr("Use Epic's saves"), role: .destructive) { Task { await cloud.resolve(appName, useCloud: true) } }
                    Button(tr("Cancel"), role: .cancel) {}
                }
            Button(tr("Keep this device's saves…")) { confirmDevice = true }
                .confirmationDialog(tr("Upload this device's saves as Epic's newest snapshot? Other devices will get them. The older snapshots stay in the cloud."),
                                    isPresented: $confirmDevice, titleVisibility: .visible) {
                    Button(tr("Upload this device's saves"), role: .destructive) { Task { await cloud.resolve(appName, useCloud: false) } }
                    Button(tr("Cancel"), role: .cancel) {}
                }
        case .upload:
            Label(tr("This device has newer saves"), systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
            summary(state)
            Button(tr("Sync now")) { Task { await cloud.syncNow(appName) } }
        case .download:
            Label(tr("Epic's cloud has newer saves"), systemImage: "icloud.and.arrow.down").foregroundStyle(.secondary)
            summary(state)
            Button(tr("Sync now")) { Task { await cloud.syncNow(appName) } }
        case .empty:
            Text(tr("No saves in Epic's cloud or on this device for this game.")).foregroundStyle(.secondary)
            Button(tr("Sync now")) { Task { await cloud.syncNow(appName) } }
        default:
            Label(tr("In sync"), systemImage: "checkmark.icloud").foregroundStyle(.secondary)
            summary(state)
            Button(tr("Sync now")) { Task { await cloud.syncNow(appName) } }
        }
        if let note = state.note { Text(note).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func summary(_ state: EpicCloud.State) -> some View {
        if state.cloudFiles > 0 { LabeledContent(tr("Epic's cloud"), value: "\(Self.when(state.cloudDate)) · \(Self.files(state.cloudFiles))") }
        if state.deviceFiles > 0 { LabeledContent(tr("This device"), value: "\(Self.when(state.deviceDate)) · \(Self.files(state.deviceFiles))") }
    }
}

/// Settings › Epic Games: the Epic Cloud saves switches (shown while signed in).
struct EpicCloudSettingRows: View {
    @ObservedObject private var setting = EpicCloudSetting.shared
    var body: some View {
        Toggle(tr("Sync saves with Epic Cloud"), isOn: $setting.on)
        if setting.on {
            Toggle(tr("Upload newer saves automatically"), isOn: $setting.autoUpload)
        }
    }
}
