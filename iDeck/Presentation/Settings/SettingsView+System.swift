// Settings: JIT, controls, graphics, storage, Windows runtime and memory.
// Split from SettingsView.swift (iDeck 3.0 architecture).

import SwiftUI

extension SettingsView {
    var jitPage: some View {
        Form {
            settingsSection(title: tr("JIT & Debugging")) {
                statusRow
            }
            Section {
                Picker(tr("Method"), selection: $jitMethod) {
                    Text("StikDebug").tag("stikdebug")
                    Text(tr("Built-in")).tag("builtIn")
                }
                // The pairing file is used only by the built-in method.
                if jitMethod == "builtIn" {
                    LabeledContent(tr("Pairing file"), value: coordinator.hasPairingFile ? tr("Imported") : tr("Missing"))
                    Button(coordinator.hasPairingFile ? tr("Replace pairing file") : tr("Import pairing file")) {
                        isPairingImporterPresented = true
                    }
                }
            } header: {
                Text(tr("Activation"))
            }
            Section {
                Picker(selection: $wineJITPoolMiB) {
                    Text(tr("Automatic")).tag(0)
                    ForEach([384, 512, 560, 624, 640, 768, 896, 1152], id: \.self) { size in
                        Text("\(size) MiB").tag(size)
                    }
                } label: {
                    Text(tr("Wine JIT pool"))
                }
                if winePoolChangeRequiresRestart {
                    Text(tr("Restart iDeck before the new Wine JIT pool size can take effect."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(tr("JIT & Debugging"))
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: coordinator.isJITEnabled ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(coordinator.isJITEnabled ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.isJITEnabled ? tr("JIT detected") : tr("JIT not detected"))
                    .font(.headline)
            }
        }
        .padding(.vertical, 4)
        if coordinator.isJITEnabled {
            LabeledContent(tr("Debugger connection")) {
                // Once Wine's JIT pool is prepared iDeck lets the debugger go on purpose
                // (early detach): that is the finished state, not a lost connection.
                if coordinator.isStikDebugAttached {
                    Text(tr("Attached")).foregroundStyle(.green)
                } else if coordinator.isWineJITPrepared {
                    Text(tr("Connected")).foregroundStyle(.green)
                } else {
                    Text(tr("Detached")).foregroundStyle(.orange)
                }
            }
        }
        if coordinator.isJITEnabled && !coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared {
            Text(tr("JIT permission is active, but StikDebug's debugger script is not connected. Use the button below to reconnect before starting Wine."))
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if !coordinator.isJITEnabled || (!coordinator.isStikDebugAttached && !coordinator.isWineJITPrepared) {
            Button {
                coordinator.requestStikDebugJIT()
            } label: {
                Label(tr(coordinator.isJITEnabled ? "Reconnect JIT debugger" : "Enable JIT"), systemImage: "bolt.fill")
            }
        }
    }

    var controlsPage: some View {
        Form {
            settingsSection(title: tr("Controller")) {
                Picker(tr("Windows controller API"), selection: $wineControllerAPI) {
                    ForEach(["By controller"] + ControllerAPI.choices, id: \.self) { api in
                        // "By controller" (the stored value) picks the API from the pad itself.
                        Text(ControllerAPI.label(api)).tag(api)
                    }
                }
                LabeledContent(tr("Connected controller")) {
                    Text(inputManager.isControllerConnected ? inputManager.controllerName : tr("Not connected"))
                        .foregroundStyle(inputManager.isControllerConnected ? .green : .secondary)
                }
                if inputManager.isControllerConnected {
                    sensitivityRow(title: tr("Left stick sensitivity"), value: $controllerLeftSensitivity)
                    sensitivityRow(title: tr("Right stick sensitivity"), value: $controllerRightSensitivity)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(tr("Stick dead zone"), value: String(format: "%.2f", controllerDeadzone))
                        Slider(value: $controllerDeadzone, in: 0...0.35, step: 0.01)
                    }
                }
            }
        }
        .navigationTitle(tr("Controls"))
    }

    var graphicsPage: some View {
        Form {
            // The everyday choices only; renderers, memory and sync are under Advanced.
            settingsSection(title: tr("Graphics & Performance")) {
                // Only a display faster than 60 Hz (ProMotion) has a higher rate to hold.
                if UIScreen.main.maximumFramesPerSecond > 60 {
                    toggleRow(title: tr("Hold Display at Maximum Rate"), isOn: $coordinator.isMaxRefreshRateEnabled)
                }
                toggleRow(title: tr("Pause games in the background"), isOn: $pauseGamesInBackground)
                toggleRow(title: "iDeck Virtual Swap", isOn: $virtualSwap)
            }
            Section {
                NavigationLink(tr("Advanced")) {
                    Form {
                        MadeiraGraphicsSettings()
                        MadeiraMemorySyncSettings()
                    }
                    .navigationTitle(tr("Advanced"))
                }
            }
        }
        .navigationTitle(tr("Graphics & Performance"))
    }

    private func capacityText(_ capacity: (free: Int64, total: Int64)?) -> String {
        guard let capacity else { return tr("Not connected") }
        return tr("%@ free of %@", ByteCountFormatter.string(fromByteCount: capacity.free, countStyle: .file),
                  ByteCountFormatter.string(fromByteCount: capacity.total, countStyle: .file))
    }

    var storagePage: some View {
        Form {
            // Free space: this device, then every connected external drive.
            Section(tr("Free space")) {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                LabeledContent(UIDevice.current.model, value: capacityText(ExternalDrives.capacity(of: documents)))
                ForEach(externalDrives.folders) { folder in
                    LabeledContent("\(folder.name) (\(folder.letter):)", value: capacityText(externalDrives.capacity(folder)))
                }
            }
            Section {
                NavigationLink { ExternalDrivesSettingsView() } label: {
                    SettingsRow(icon: "externaldrive.fill", color: .teal, title: tr("External drives"),
                                value: externalDrives.folders.isEmpty ? tr("None") : "\(externalDrives.folders.count)")
                }
                if let missing = externalDrives.installFolderMissing {
                    Text(tr("The install drive \"%@\" is not connected; new games go to this device.", missing))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                toggleRow(title: tr("Continue downloads in the background"), isOn: $continueDownloadsInBackground)
                toggleRow(title: tr("Download notifications"), isOn: $downloadNotifications)
                    .disabled(notificationsDenied)
            } header: {
                Text(tr("Downloads"))
            }
        }
        .navigationTitle(tr("Storage & Downloads"))
    }

    var runtimePage: some View {
        Form {
            settingsSection(title: tr("Windows runtime")) {
                Button(tr("Undo automatic DLLs")) {
                    let removed = AutoDLLManager.rollbackAll()
                    autoDLLNotice = tr("%d DLL(s) removed.", removed)
                }
                .disabled(AutoDLLManager.ledger().isEmpty)
                if let autoDLLNotice { Text(autoDLLNotice).font(.footnote).foregroundStyle(.secondary) }
                let runtime = MadeiraBundleIdentity.profile
                LabeledContent(tr("IPA runtime")) {
                    Text(tr(MadeiraBundleIdentity.isNative ? "Madeira-native" : "Interface-only"))
                        .foregroundStyle(MadeiraBundleIdentity.isNative ? .green : .orange)
                }
                LabeledContent(tr("Graphics profile"), value: MadeiraBundleIdentity.graphicsProfile)
                LabeledContent("Direct3D 11 (DXMT)",
                               value: tr(MadeiraBundleIdentity.d3d11Available ? "Bundled" : "Not bundled"))
                LabeledContent("Direct3D 12 (Madeira)",
                               value: tr(MadeiraBundleIdentity.d3d12Available ? "Bundled" : "Not bundled"))
                LabeledContent("WoW64", value: tr((runtime["wow64Enabled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent("Wine Mono", value: tr((runtime["wineMonoBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent("Metal Shader Converter",
                               value: tr((runtime["metalShaderConverterBundled"] as? Bool ?? false) ? "Bundled" : "Not bundled"))
                LabeledContent(tr("Madeira Dock"), value: tr(MadeiraDock.bundled ? "Bundled" : "Not bundled"))
                if !MadeiraBundleIdentity.isNative {
                    Text(tr(MadeiraBundleIdentity.missingRuntimeMessage))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            memoryPlusSection
        }
        .navigationTitle(tr("Windows runtime"))
    }

    private func memoryPlusValue(_ state: MemoryPlus.State) -> Text {
        switch state {
        case .granted: return Text(tr("Active")).foregroundColor(.green)
        case .missing: return Text(tr("Not granted")).foregroundColor(.orange)
        case .unknown: return Text(tr("Unknown")).foregroundColor(.secondary)
        }
    }

    /// Memory+ as this installed copy has it, and GetMoreRam's steps when it is missing.
    private var memoryPlusSection: some View {
        settingsSection(title: "Memory+") {
            LabeledContent(tr("Increased Memory Limit")) { memoryPlusValue(MemoryPlus.increasedLimit) }
            LabeledContent(tr("Extended Virtual Addressing")) { memoryPlusValue(MemoryPlus.extendedAddressing) }
            LabeledContent(tr("Memory iOS still allows"), value: "\(ResourceGovernor.availableMiB()) MB")
            LabeledContent("App ID") {
                Text(MemoryPlus.appID).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button(tr("Copy App ID")) { UIPasteboard.general.string = MemoryPlus.appID }
            Link(tr("Open GetMoreRam"), destination: MemoryPlus.getMoreRamURL)
        }
    }
}
