// Settings: language, updates and the shared rows.
// Split from SettingsView.swift (iDeck 3.0 architecture).

import SwiftUI
import UserNotifications

extension SettingsView {
    var languagePicker: some View {
        Picker(selection: $appLanguage) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language.rawValue)
            }
        } label: {
            SettingsRow(icon: "globe", color: .blue, title: tr("Language"))
        }
        .pickerStyle(.menu)
    }

    var updatesPage: some View {
        Form {
            settingsSection(title: tr("Updates")) {
                ForEach(updater.statuses) { status in
                    LabeledContent(status.project.name, value: versionText(for: status))
                }
                Button {
                    Task { await updater.check() }
                } label: {
                    HStack {
                        Text(updater.isChecking ? tr("Checking...") : tr("Check for Updates"))
                        if updater.isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(updater.isChecking)
                // The Version section (installed version, releases link, sideloading
                // note) is gone: the row above already shows the installed version.
                if updater.availableIDeckUpdate != nil {
                    Button(tr("Install update")) {
                        updater.installIDeckUpdate()
                    }
                }
                if let message = updater.installHandoffMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(tr("Updates"))
    }

    /// Installed iDeck version, plus the newest release with an IPA once checked.
    private func versionText(for status: ProjectStatus) -> String {
        let installed = "v\(updater.currentVersion)"
        guard updater.hasChecked, !status.failed, let latest = status.latest,
              UpdateChecker.isNewer(latest, than: updater.currentVersion) else { return installed }
        return installed + " → " + latest
    }

    func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        Section(title) { content() }
    }

    func sensitivityRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title, value: String(format: "%.2fx", value.wrappedValue))
            Slider(value: value, in: 0.25...2.0, step: 0.05)
        }
    }

    /// Reads iDeck's notification permission; when refused, Download notifications
    /// is switched off and greyed out.
    func refreshNotificationPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
        // Only an allowed permission shows the switch on: "Don't Allow" or a prompt
        // that was dismissed showed it on before.
        if status != .authorized && status != .provisional && status != .ephemeral { downloadNotifications = false }
    }

    func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
    }
}
