// IDeckFirstRunSetupView.swift
// Split from MainView.swift (iDeck 3.0 architecture).

import SwiftUI

struct IDeckFirstRunSetupView: View {
    @Environment(\.verticalSizeClass) var setupHeight
    var compactPhone: Bool { setupHeight == .compact && UIDevice.current.userInterfaceIdiom == .phone }
    @ObservedObject var coordinator: SystemCoordinator
    let onFinish: () -> Void

    @AppStorage(SystemCoordinator.jitMethodKey) var jitMethod = "stikdebug"
    @ObservedObject var wineMono = WineMonoModel.shared
    @AppStorage("firstRunSetup.step.v2") var step = 0
    /// The JIT step counts as done only after a method was picked here: the stored
    /// default ("stikdebug") used to show the step finished before any choice.
    @AppStorage("firstRunSetup.jitMethodChosen") var jitMethodChosen = false
    @State var installing = false
    @State var installerStatus = ""
    @State var refresh = 0
    @State var pairingImporterPresented = false
    @State var eaAppInstalled = false
    @State var ubisoftConnectInstalled = false
    /// The launchers step starts their installation once per appearance.

    private enum Step: Int, CaseIterable {
        case visualCpp, wineMono, dock, launchers, jit, summary
        var title: String {
            switch self {
            case .visualCpp: return "Visual C++"
            case .wineMono: return "Wine Mono"
            case .dock: return "Madeira Dock"
            case .launchers: return "Launchers"
            case .jit: return "JIT"
            case .summary: return "Summary"
            }
        }
        var icon: String {
            switch self {
            case .visualCpp: return "shippingbox.fill"
            case .wineMono: return "gearshape.2.fill"
            case .dock: return "dock.rectangle"
            case .launchers: return "square.grid.2x2.fill"
            case .jit: return "bolt.fill"
            case .summary: return "checkmark.seal.fill"
            }
        }
        var tint: Color {
            switch self {
            case .visualCpp: return .blue
            case .wineMono: return .purple
            case .dock: return .teal
            case .launchers: return .red
            case .jit: return .orange
            case .summary: return .green
            }
        }
    }

    // Palette: one neutral background, one card surface, one hairline.
    let background = Color(red: 0.043, green: 0.047, blue: 0.063)
    let surface = Color(red: 0.094, green: 0.102, blue: 0.129)
    let hairline = Color.white.opacity(0.08)

    var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var prefixReady: Bool { PrefixInstaller.isPrefixInstalled(at: MadeiraDock.prefix) }
    /// The Windows runtime itself is part of the IPA; the Wine environment (prefix)
    /// is prepared by the Visual C++ step before the runtimes go into it.
    var vcReady: Bool {
        VisualCRuntimeBootstrap.installed(in: MadeiraDock.prefix, documents: documents)
            && VisualCRuntimeLegacy.installed(documents: documents)
    }
    var steamDLLsReady: Bool {
        guard let folder = SteamDLLRepair.sourceFolder else { return false }
        let root = MadeiraDock.prefix.appendingPathComponent("drive_c")
            .appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true)
        return (SteamDLLRepair.mediaLibraries + [SteamDLLRepair.sdlLibrary]).allSatisfy {
            SteamDLLRepair.validX64DLL(folder.appendingPathComponent($0))
                || SteamDLLRepair.validX64DLL(root.appendingPathComponent($0))
        }
    }

    private func done(_ item: Step) -> Bool {
        switch item {
        case .visualCpp: return prefixReady && vcReady
        case .wineMono: return wineMono.installed
        case .dock: return MadeiraDock.clientInstalled && steamDLLsReady && !coordinator.steamComponentsInstalling
        case .launchers: return eaAppInstalled && ubisoftConnectInstalled
        case .jit: return jitMethodChosen && (jitMethod != "builtIn" || coordinator.hasPairingFile)
        case .summary: return false
        }
    }

    var body: some View {
        let current = Step(rawValue: step) ?? .summary
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: setupHeight == .compact ? 10 : 28) {
                        if setupHeight == .compact {
                            HStack(spacing: 16) {
                                header(current).frame(maxWidth: 270)
                                stepper(current)
                            }
                        } else {
                            header(current)
                            stepper(current)
                        }
                        VStack(alignment: .leading, spacing: 20) {
                            switch current {
                            case .visualCpp: visualCppStep
                            case .wineMono: wineMonoStep
                            case .dock: dockStep
                            case .launchers: launchersStep
                            case .jit: jitStep
                            case .summary: completeStep
                            }
                        }
                        .id(refresh)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(hairline, lineWidth: 1))
                        if setupHeight != .compact { footer(current) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, setupHeight == .compact ? 8 : 32)
                    .frame(maxWidth: setupHeight == .compact ? 840 : 640)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if setupHeight == .compact {
                    footer(current).padding(.horizontal, 20).padding(.vertical, 4).background(background)
                }
            }
            .navigationBarHidden(true)
        }
        .fileImporter(isPresented: $pairingImporterPresented,
                      allowedContentTypes: [.propertyList, .xml, .json, .data]) { result in
            if case .success(let url) = result { coordinator.importPairingFile(at: url) }
        }
        .onAppear {
            coordinator.refreshJITStatus()
            coordinator.refreshPairingFileState()
            wineMono.refresh()
        }
        .task {
            // The launchers' rows follow what their installers put in the prefix.
            while !Task.isCancelled {
                await refreshLaunchers()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Layout

    private func header(_ current: Step) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: compactPhone ? 16 : 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compactPhone ? 34 : 48, height: compactPhone ? 34 : 48)
                .background(LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to iDeck")
                    .font(.system(size: compactPhone ? 20 : 26, weight: .bold))
                    .foregroundStyle(.white)
                Text("Step \(current.rawValue + 1) of \(Step.allCases.count) · \(current.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Numbered steps joined by a line; finished ones show a check. Tappable when idle.
    private func stepper(_ current: Step) -> some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                let isCurrent = item == current
                let finished = done(item) && !isCurrent
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { step = item.rawValue }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? item.tint : (finished ? Color.green.opacity(0.18) : surface))
                                .overlay(Circle().stroke(isCurrent ? Color.clear : hairline, lineWidth: 1))
                                .frame(width: compactPhone ? 24 : 32, height: compactPhone ? 24 : 32)
                            if finished {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                            } else {
                                Text("\(item.rawValue + 1)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(isCurrent ? .white : .secondary)
                            }
                        }
                        Text(item.title)
                            .font(.caption2.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(installing || wineMono.busy)
                if item != Step.allCases.last {
                    Rectangle()
                        .fill(done(item) ? Color.green.opacity(0.5) : hairline)
                        .frame(height: 1)
                        .frame(maxWidth: 28)
                        .offset(y: -10)
                }
            }
        }
    }

    private func footer(_ current: Step) -> some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { step -= 1 } } label: {
                    Label("Back", systemImage: "chevron.left").frame(minWidth: 90)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            Spacer()
            if current != .summary {
                Button { withAnimation(.easeInOut(duration: 0.2)) { step += 1 } } label: {
                    HStack(spacing: 6) { Text("Continue"); Image(systemName: "chevron.right") }.frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing || wineMono.busy
                          || (current == .visualCpp && !(prefixReady && vcReady))
                          || (current == .wineMono && !wineMono.installed)
                          || (current == .dock && (!MadeiraDock.clientInstalled || !steamDLLsReady
                                                   || coordinator.steamComponentsInstalling)))
            } else {
                Button { step = 0; onFinish() } label: { Text("Start using iDeck").frame(minWidth: 160) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .controlSize(.large)
        .disabled(installing)
    }

    /// The top of a step: tinted icon tile, title and one line of explanation.
    private func stepHeader(_ item: Step, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 40, height: 40)
                .background(item.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Component rows inside a step, drawn as a grouped list.
    private func componentList<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        VStack(spacing: 0) { rows() }
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hairline, lineWidth: 1))
    }

    private func statusRow(_ title: String, _ ready: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(ready ? Color.green : Color.secondary)
            Text(title).font(.body).foregroundStyle(.white)
            Spacer(minLength: 8)
            Text(detail ?? (ready ? "Installed" : "Not installed"))
                .font(.caption.weight(.medium))
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((ready ? Color.green : Color.white).opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func primaryButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var progressNote: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(installerStatus.isEmpty ? coordinator.windowsStatus : installerStatus)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Visual C++

    var visualCppStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.visualCpp, "Installs Microsoft Visual C++ 2005–2022, which most games and programs need.")
            componentList {
                statusRow("Microsoft Visual C++ 2005–2022", vcReady)
            }
            primaryButton(prefixReady && vcReady ? "Installed" : (installing ? "Installing…" : "Install"),
                          systemImage: prefixReady && vcReady ? "checkmark" : "arrow.down.circle",
                          disabled: installing || (prefixReady && vcReady) || !MadeiraRuntime.available) {
                installVisualCpp()
            }
            if installing { progressNote }
            else if !installerStatus.isEmpty { note(installerStatus) }
            if !MadeiraRuntime.available {
                note("This IPA does not include the Windows runtime. Install a native iDeck IPA.", warning: true)
            }
        }
    }

    // MARK: - Wine Mono

    var wineMonoStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.wineMono, "Installs Wine Mono, the .NET Framework that programs and launchers built with .NET need.")
            componentList {
                statusRow("Wine Mono \(WineMonoPin.version)", wineMono.installed, detail: wineMono.busy ? wineMono.status : nil)
            }
            primaryButton(wineMono.installed ? "Installed" : (wineMono.busy ? "Installing…" : "Install"),
                          systemImage: wineMono.installed ? "checkmark" : "arrow.down.circle",
                          disabled: wineMono.installed || wineMono.busy) {
                wineMono.install()
            }
            if wineMono.busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(wineMono.status).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = wineMono.error { note(error, warning: true) }
            note("Downloaded from WineHQ, about \(Int((Double(WineMonoPin.tarBytes) / 1_000_000).rounded())) MB.")
        }
    }

    /// Prepares the Wine environment, then installs every Visual C++ runtime; each
    /// part is skipped when present.
    private func installVisualCpp() {
        guard !installing else { return }
        installing = true
        let docs = documents
        Task { @MainActor in
            defer { installing = false; refresh += 1 }
            // An IPA built with a split runtime downloads Wine's Windows files first.
            for package in MadeiraRuntime.packages where !MadeiraRuntime.installed(package.id) {
                do {
                    try await MadeiraRuntime.install(package.id) { message, fraction in
                        Task { @MainActor in installerStatus = "\(message) \(Int(fraction * 100))%" }
                    }
                } catch {
                    installerStatus = error.localizedDescription
                    return
                }
            }
            if !prefixReady {
                installerStatus = "Preparing the Windows environment…"
                coordinator.openMadeiraWorkspace()
                for _ in 0..<600 where !prefixReady {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard prefixReady else {
                    installerStatus = "The Windows environment could not be prepared: \(coordinator.windowsStatus)"
                    return
                }
            }
            refresh += 1
            // 2015-2022 x64 (vcruntime140 & co.).
            if !VisualCRuntimeBootstrap.installed(in: MadeiraDock.prefix, documents: docs) {
                installerStatus = "Downloading Microsoft Visual C++ 2015-2022 (x64)…"
                let downloaded: Result<URL, Error> = await withCheckedContinuation { done in
                    VisualCRuntimeBootstrap.download(in: MadeiraDock.prefix) { done.resume(returning: $0) }
                }
                guard case .success(let installer) = downloaded else {
                    if case .failure(let error) = downloaded { installerStatus = error.localizedDescription }
                    return
                }
                installerStatus = "Installing Microsoft Visual C++ 2015-2022 (x64)…"
                let installed: Result<Void, Error> = await withCheckedContinuation { done in
                    VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: docs) { done.resume(returning: $0) }
                }
                if case .failure(let error) = installed { installerStatus = error.localizedDescription; return }
            }
            // 2005-2013 (x86/x64) and 2015-2022 x86.
            if !VisualCRuntimeLegacy.installed(documents: docs) {
                let failures = await VisualCRuntimeLegacy.installAll(documents: docs) { name in
                    Task { @MainActor in installerStatus = "Installing Microsoft Visual C++ \(name)…" }
                }
                if !failures.isEmpty {
                    installerStatus = "Some runtimes failed: " + failures.joined(separator: "; ") + ". Tap Install to retry."
                    return
                }
            }
            installerStatus = vcReady ? "Visual C++ installed." : "Some components are missing. Tap Install to retry."
        }
    }

    // MARK: - Madeira Dock

    var dockStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.dock, "Launches games through Steam.")
            componentList {
                statusRow("Steam client", MadeiraDock.clientInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Steam DLLs", steamDLLsReady)
            }
            primaryButton(MadeiraDock.clientInstalled ? "Repair Madeira Dock" : "Install Madeira Dock",
                          systemImage: MadeiraDock.clientInstalled ? "wrench.and.screwdriver" : "arrow.down.circle",
                          disabled: !MadeiraDock.bundled || !prefixReady) {
                coordinator.installMadeiraDock()
            }
            if let progress = coordinator.steamComponentsProgress {
                note(progress, warning: progress.contains("failed") || progress.contains("missing"))
            }
            if !prefixReady {
                note("Install Visual C++ first: it prepares the Windows environment.", warning: true)
            }
        }
    }

    // MARK: - Launchers

    var launchersBusy: Bool {
        coordinator.storeClientDownload != nil || coordinator.storeSetupInBackground
            || coordinator.windowsStatus.hasPrefix("Running")
            || coordinator.windowsStatus.hasPrefix("Wine started") || coordinator.windowsStatus.hasPrefix("Launching")
            || coordinator.windowsStatus.hasPrefix("Preparing executable")
    }

    var launchersStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.launchers, "Installs the EA app and Ubisoft Connect, so their games can start.")
            componentList {
                statusRow("EA app", eaAppInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Ubisoft Connect", ubisoftConnectInstalled)
            }
            primaryButton(done(.launchers) ? "Installed" : (launchersBusy ? "Installing…" : "Install"),
                          systemImage: done(.launchers) ? "checkmark" : "arrow.down.circle",
                          disabled: done(.launchers) || launchersBusy || !prefixReady) {
                coordinator.installDefaultStoreClients()
            }
            if let progress = coordinator.storeClientDownload {
                note(progress)
            } else if launchersBusy {
                // The Visual C++ step's own text stayed in installerStatus and was shown here.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tr("Installing %@...", launchersInstalling))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = coordinator.storeClientError {
                note(error, warning: true)
            }
            if !prefixReady {
                note("Install Visual C++ first: it prepares the Windows environment.", warning: true)
            } else {
                note("Sign in to EA and Ubisoft in Settings › Stores & launchers to see your games.")
            }
        }
        // The launchers install only when Install is tapped.
        .task { await refreshLaunchers() }
    }

    /// The launchers the Install button installs, for the progress line.
    var launchersInstalling: String {
        var names: [String] = []
        if !eaAppInstalled { names.append("EA app") }
        if !ubisoftConnectInstalled { names.append("Ubisoft Connect") }
        return names.isEmpty ? "EA app / Ubisoft Connect" : names.joined(separator: " / ")
    }

    private func refreshLaunchers() async {
        let (ea, ubisoft) = await Task.detached(priority: .utility) {
            (SystemCoordinator.StoreClient.ea.installedURL != nil,
             SystemCoordinator.StoreClient.ubisoft.installedURL != nil)
        }.value
        eaAppInstalled = ea
        ubisoftConnectInstalled = ubisoft
    }

    // MARK: - JIT

    var jitStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.jit, "Choose how iDeck turns JIT on each time a game starts.")
            Picker("JIT method", selection: Binding(
                get: { jitMethodChosen ? jitMethod : "" },
                set: { jitMethod = $0; jitMethodChosen = true })) {
                Text("StikDebug").tag("stikdebug")
                Text("Built-in").tag("builtIn")
            }
            .pickerStyle(.segmented)
            if !jitMethodChosen {
                note("Pick StikDebug or Built-in to finish this step.")
            } else if jitMethod == "builtIn" {
                componentList {
                    statusRow("Pairing file", coordinator.hasPairingFile, detail: coordinator.hasPairingFile ? "Imported" : "Missing")
                }
                Button(coordinator.hasPairingFile ? "Replace pairing file" : "Import pairing file") {
                    pairingImporterPresented = true
                }
                .buttonStyle(.bordered)
                note("Built-in turns JIT on from inside iDeck with this device's pairing file.")
            } else {
                note("iDeck opens StikDebug when a game starts, and StikDebug turns JIT on for it.")
            }
        }
    }

    // MARK: - Summary

    var completeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(.summary, "Everything iDeck needs. Unfinished items can be completed later from Settings.")
            componentList {
                statusRow("Visual C++", prefixReady && vcReady)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Wine Mono", wineMono.installed)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Madeira Dock", MadeiraDock.clientInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("EA app", eaAppInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("Ubisoft Connect", ubisoftConnectInstalled)
                Divider().overlay(hairline).padding(.leading, 43)
                statusRow("JIT method", done(.jit), detail: !jitMethodChosen ? "Not chosen" : (jitMethod == "builtIn" ? "Built-in" : "StikDebug"))
            }
        }
    }
}
