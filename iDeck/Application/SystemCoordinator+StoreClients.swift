// SystemCoordinator: Visual C++ runtime and the store clients.
// Split from SystemCoordinator.swift (iDeck 3.0 architecture).

import Foundation
import UIKit

extension SystemCoordinator {
    func approveVisualCRuntimeInstallation() {
        guard let action = visualCRuntimeConsentAction else { return }
        needsVisualCRuntimeConsent = false
        visualCRuntimeConsentAction = nil
        visualCRuntimeSkipAction = nil
        UserDefaults.standard.set(true, forKey: "ideckInstallOfficialVisualCRedist")
        action()
    }

    func skipVisualCRuntimeInstallation() {
        let action = visualCRuntimeSkipAction
        guard action != nil else { return }
        needsVisualCRuntimeConsent = false
        visualCRuntimeConsentAction = nil
        visualCRuntimeSkipAction = nil
        action?()
    }

    private static func fileStamp(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return "\(values.fileSize ?? -1)@\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
    }

    /// On demand, before Wine starts: the Visual C++ runtime (by version and
    /// architecture) and .NET support (Wine Mono) that `executable` imports, and
    /// nothing else. Returns true when it installs and calls `resume` afterwards.
    func prepareVisualCRuntimeIfNeeded(prefix: URL, executable: URL?, resume: @escaping () -> Void) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                _ = self?.prepareVisualCRuntimeIfNeeded(prefix: prefix, executable: executable, resume: resume)
            }
            return true
        }
        if onDemandInstallTask != nil { return true }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        // Visual C++ built into a development app: in place without installing anything
        // (checked once per run: the marker does not change while iDeck runs).
        if !bundledRuntimeChecked, let documents {
            bundledRuntimeChecked = VisualCRuntimeBootstrap.installBundled(documents: documents)
                || !VisualCRuntimeBootstrap.bundled
        }
        guard let executable else { return false }
        lastPreparedExecutable = executable
        // A program already found complete in this run, unchanged since, is not read
        // and checked again (PE imports, Visual C++, Mono, D3DX lookups).
        let stamp = Self.fileStamp(executable)
        if let stamp, satisfiedExecutables[executable.path] == stamp { return false }
        guard let pe = WindowsPEInfo.read(executable),
              !onDemandAttempted.contains(executable.path) else { return false }
        let needed = MainActor.assumeIsolated { WindowsInstallerEnvironment.missing(WindowsRequirements.of(pe)) }
        let d3dx = NativeD3DX.wanted(executable) && !NativeD3DX.installed(for: executable)
        guard !needed.isEmpty || d3dx else {
            if let stamp { satisfiedExecutables[executable.path] = stamp }
            return false
        }
        onDemandAttempted.insert(executable.path)
        AppLog.record("[installer] \(executable.lastPathComponent) needs \(needed)\(d3dx ? " and Microsoft's D3DX 9" : "")")
        onDemandInstallTask = Task { @MainActor [weak self] in
            var failures: [String] = []
            if !needed.isEmpty {
                failures = await WindowsInstallerEnvironment.install(needed) { [weak self] message in
                    self?.setWindowsStatus(message)
                }
            }
            if d3dx {
                self?.setWindowsStatus("Installing Microsoft D3DX 9 and its shader compiler (about 95 MB, once)…")
                do { try await NativeD3DX.provide(for: executable, machine: pe.machine, prefix: prefix) }
                catch {
                    AppLog.record("[d3dx] not provided: \(error.localizedDescription)")
                    failures.append("Microsoft D3DX 9: \(error.localizedDescription)")
                }
            }
            self?.onDemandInstallTask = nil
            if !failures.isEmpty { self?.setWindowsStatus(failures.joined(separator: "\n")) }
            resume()
        }
        return true
    }

    enum StoreClient: String, CaseIterable {
        case ubisoft = "Ubisoft Connect", ea = "EA app"

        static func required(for publishers: [String], title: String) -> Self? {
            for publisher in publishers {
                let name = publisher.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("ubisoft") || name == "uplay" { return .ubisoft }
                if name.hasPrefix("electronic arts") || ["ea", "ea sports", "ea originals", "origin"].contains(name) {
                    let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
                    return words.prefix(2).elementsEqual(["battlefield", "6"]) ? nil : .ea
                }
            }
            return nil
        }

        var installInstruction: String {
            tr("Install it in Settings › Stores & launchers › %@.", rawValue)
        }

        static var drive: URL { MadeiraDock.prefix.appendingPathComponent("drive_c") }

        var installedURL: URL? { installedURL(prefix: MadeiraDock.prefix) }

        /// The launcher in `prefix`, or nil when it is not installed there.
        func installedURL(prefix: URL) -> URL? {
            let drive = prefix.appendingPathComponent("drive_c")
            var folders: [String] = []
            let names: [String]
            switch self {
            case .ubisoft:
                // Where the installer put it (its own registry value), then both Program
                // Files folders: a 64-bit installer does not use Program Files (x86), so
                // checking that folder alone missed an installed launcher.
                if let dir = Self.registryValue(key: "Software\\Wow6432Node\\Ubisoft\\Launcher", name: "InstallDir", prefix: prefix)
                    ?? Self.registryValue(key: "Software\\Ubisoft\\Launcher", name: "InstallDir", prefix: prefix) {
                    folders.append(dir)
                }
                folders += ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher", "Program Files/Ubisoft/Ubisoft Game Launcher"]
                names = ["UbisoftConnect.exe", "upc.exe"]
            case .ea:
                folders = ["Program Files/Electronic Arts/EA Desktop/EA Desktop", "Program Files (x86)/Electronic Arts/EA Desktop/EA Desktop"]
                names = ["EADesktop.exe"]
            }
            for folder in folders {
                for name in names {
                    let url = drive.appendingPathComponent(folder).appendingPathComponent(name)
                    if VisualCRuntimeBootstrap.hasPE(url, machines: [0x014c, 0x8664, 0xaa64]) { return url }
                }
            }
            return nil
        }

        /// A C:\ path value from the prefix's system.reg, as a drive-relative path.
        static func registryValue(key: String, name: String, prefix: URL = MadeiraDock.prefix) -> String? {
            let file = prefix.appendingPathComponent("system.reg")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            // Wine's .reg files write each backslash of a key name twice.
            let header = "[" + key.lowercased().replacingOccurrences(of: "\\", with: "\\\\") + "]"
            var inside = false
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let end = text.utf8[cursor...].firstIndex(of: 10) ?? text.endIndex
                let line = text.utf8[cursor..<end]
                cursor = end == text.endIndex ? end : text.utf8.index(after: end)
                let l = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if l.hasPrefix("[") { inside = l.lowercased().hasPrefix(header); continue }
                guard inside, l.lowercased().hasPrefix("\"" + name.lowercased() + "\"=\"") else { continue }
                var value = String(l.dropFirst(name.count + 4).dropLast())
                value = value.replacingOccurrences(of: "\\\\", with: "/")
                guard value.lowercased().hasPrefix("c:/") else { return nil }
                return String(value.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return nil
        }

        /// The official installer, downloaded when the user taps Install (not in the IPA).
        var downloadURL: URL {
            switch self {
            case .ubisoft: return URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
            case .ea: return URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!
            }
        }

        var installerName: String { downloadURL.lastPathComponent }

        struct InstallError: Error { let reason: String }

        /// Where the launcher's files go, relative to drive_c.
        var installFolder: String {
            switch self {
            case .ubisoft: return "Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
            case .ea: return "Program Files/Electronic Arts/EA Desktop"
            }
        }

        /// Downloads the official installer and copies the launcher's files into the
        /// prefix, as its installer would: Ubisoft Connect's NSIS installer is opened
        /// on the device; the EA app's installer only names the Windows Installer
        /// package it downloads, which is downloaded and opened instead.
        static func installWithoutWine(_ client: StoreClient, progress: @escaping @MainActor (String) -> Void) async throws {
            let fm = FileManager.default
            let drive = Self.drive
            let folder = drive.appendingPathComponent("iDeck", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if client.installer == nil {
                await progress(tr("Downloading %@ installer...", client.rawValue))
                try await download(client.downloadURL, to: folder.appendingPathComponent(client.installerName))
            }
            guard let installer = client.installer else {
                throw InstallError(reason: tr("The installer is missing or invalid."))
            }
            var archive = installer
            if client == .ea {
                let manifest = folder.appendingPathComponent("EAappInstaller-manifest.xml")
                defer { try? fm.removeItem(at: manifest) }
                try await Task.detached(priority: .userInitiated) {
                    try check { ideck_burn_manifest(installer.path, manifest.path, $0, $1) }
                }.value
                guard let package = packageURL(manifest: (try? String(contentsOf: manifest, encoding: .utf8)) ?? "") else {
                    throw InstallError(reason: tr("The installer does not name the EA app's package."))
                }
                archive = folder.appendingPathComponent(package.lastPathComponent)
                if !fm.fileExists(atPath: archive.path) {
                    await progress(tr("Downloading %@...", client.rawValue))
                    try await download(package, to: archive)
                }
            }
            await progress(tr("Installing %@...", client.rawValue))
            // Extracted next to drive_c (same volume), then moved into place.
            let staging = folder.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let target = client == .ubisoft ? staging.appendingPathComponent(client.installFolder, isDirectory: true) : staging
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let source = archive
            try await Task.detached(priority: .userInitiated) {
                if client == .ubisoft {
                    try check { ideck_nsis_extract(source.path, target.path, $0, $1) }
                } else {
                    try check { ideck_msi_extract(source.path, target.path, $0, $1) }
                }
            }.value
            try await Task.detached(priority: .userInitiated) { try merge(staging, into: drive) }.value
            if client == .ea { try? fm.removeItem(at: archive) }
            guard client.installedURL != nil else {
                throw InstallError(reason: tr("The launcher's files were copied, but its program is missing."))
            }
            writeRegistry(client)
        }

        /// Runs an extractor call with an error buffer; a negative result throws its reason.
        private static func check(_ call: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
            var message = [CChar](repeating: 0, count: 512)
            let result = message.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
            if result < 0 { throw InstallError(reason: tr(String(cString: message))) }
        }

        /// The Windows Installer package a Burn manifest downloads, on EA's own server only.
        static func packageURL(manifest: String) -> URL? {
            guard let range = manifest.range(of: #"DownloadUrl="https://[^"]+\.msi""#, options: .regularExpression) else { return nil }
            let value = manifest[range].dropFirst("DownloadUrl=\"".count).dropLast()
            guard let url = URL(string: String(value)), url.scheme == "https",
                  url.host == "origin-a.akamaihd.net", url.path.hasPrefix("/EA-Desktop-Client-Download/") else { return nil }
            return url
        }

        private static func download(_ url: URL, to target: URL) async throws {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileReadUnknown)
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        }

        /// Moves every file of `staging` to the same place under `drive`, replacing
        /// an older copy (a launcher reinstalled over itself).
        static func merge(_ staging: URL, into drive: URL) throws {
            let fm = FileManager.default
            let base = staging.standardizedFileURL.path + "/"
            guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            for case let file as URL in walker {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
                guard !relative.isEmpty, !relative.hasPrefix(".") else { continue }
                let destination = drive.appendingPathComponent(relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: file, to: destination)
            }
        }

        /// The registry values the installer would write: the install folder (read by
        /// games and by installedURL), and the EA app's background service.
        static func writeRegistry(_ client: StoreClient, prefix: URL = MadeiraDock.prefix) {
            guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
            let windowsFolder = "C:\\" + client.installFolder.replacingOccurrences(of: "/", with: "\\")
            var values: [SteamInstallValue]
            switch client {
            case .ubisoft:
                values = ["Software\\Wow6432Node\\Ubisoft\\Launcher", "Software\\Ubisoft\\Launcher"].map {
                    SteamInstallValue(hive: .machine, key: $0, name: "InstallDir", data: .string(windowsFolder + "\\"), followsInstall: true)
                }
            case .ea:
                let service = "System\\CurrentControlSet\\Services\\EABackgroundService"
                let program = windowsFolder + "\\EA Desktop\\EABackgroundService.exe"
                values = [
                    SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallLocation",
                                      data: .string(windowsFolder), followsInstall: true),
                    SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallSuccessful",
                                      data: .string("true"), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "Type", data: .dword(0x110), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "Start", data: .dword(3), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "ErrorControl", data: .dword(1), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "ImagePath",
                                      data: .string("\"" + program + "\" -start"), followsInstall: true),
                    SteamInstallValue(hive: .machine, key: service, name: "DisplayName",
                                      data: .string("EABackgroundService"), followsInstall: false),
                    SteamInstallValue(hive: .machine, key: service, name: "ObjectName",
                                      data: .string("LocalSystem"), followsInstall: false),
                ]
            }
            do {
                let changed = try EARegistry.write(values, prefix: prefix)
                AppLog.record("[store-setup] \(client.rawValue): \(changed) registry line(s) written")
            } catch {
                AppLog.record("[store-setup] \(client.rawValue): registry not written: \(error.localizedDescription)")
            }
        }

        /// The programs of the EA app and Ubisoft Connect that check which Windows
        /// they run on: the EA app needs Windows 10 or later and refused to install
        /// on an older version. Written while no session runs (the registry is on disk).
        static let windows10Programs = ["EAappInstaller.exe", "EADesktop.exe", "EABackgroundService.exe",
                                        "EALauncher.exe", "EALocalHostSvc.exe", "EACrashReporter.exe",
                                        "UbisoftConnectInstaller.exe", "UbisoftConnect.exe", "upc.exe", "UplayService.exe"]

        static func prepareInstallEnvironment(prefix: URL = MadeiraDock.prefix) {
            guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
                AppLog.record("[store-setup] Windows version not set: a Windows session is still running")
                return
            }
            let values = windows10Programs.map {
                SteamInstallValue(hive: .user, key: "Software\\Wine\\AppDefaults\\" + $0, name: "Version",
                                  data: .string("win10"), followsInstall: true)
            }
            do {
                let changed = try EARegistry.write(values, prefix: prefix)
                // The installers write under %TEMP%: make sure the profile's folder exists.
                if let user = SteamCloudPaths.userFolder(drive: prefix.appendingPathComponent("drive_c"))?.url {
                    try? FileManager.default.createDirectory(at: user.appendingPathComponent("AppData/Local/Temp"),
                                                             withIntermediateDirectories: true)
                }
                AppLog.record("[store-setup] Windows 10 reported to the EA app and Ubisoft Connect (\(changed) registry line(s) changed)")
            } catch {
                AppLog.record("[store-setup] Windows version not set: \(error.localizedDescription)")
            }
        }

        /// The launcher an executable is (EA app, Ubisoft Connect), or nil for any other program.
        static func displayName(for executable: URL) -> String? {
            switch executable.lastPathComponent.lowercased() {
            case "ubisoftconnect.exe", "upc.exe": return Self.ubisoft.rawValue
            case "eadesktop.exe": return Self.ea.rawValue
            default: return nil
            }
        }

        /// The downloaded installer in C:\iDeck, when present.
        var installer: URL? {
            let url = Self.drive.appendingPathComponent("iDeck/" + installerName)
            return VisualCRuntimeBootstrap.hasPE(url, machines: [0x014c, 0x8664, 0xaa64]) ? url : nil
        }
    }

    /// Installs the launcher when it is missing. An installed launcher is not opened from
    /// iDeck: its games are on its store page.
    func openStoreClient(_ client: StoreClient) {
        guard client.installedURL == nil else { return }
        installDefaultStoreClients([client])
    }

    /// Installs the EA app and Ubisoft Connect without Wine or JIT: each official
    /// installer is downloaded and opened on the device (LauncherArchiveExtractor),
    /// its files are copied into the prefix and its registry values written. No
    /// Windows program runs, so nothing waits for StikDebug or a Metal surface.
    func installDefaultStoreClients(_ clients: [StoreClient] = StoreClient.allCases) {
        guard !isClosingWindowsSession, !ideck_wineprocess_running(), storeClientDownload == nil,
              !storeSetupInBackground else { return }
        let missing = clients.filter { $0.installedURL == nil }
        guard !missing.isEmpty else { return }
        storeSetupInBackground = true
        storeClientError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.storeClientDownload = nil
                self.storeSetupInBackground = false
            }
            for client in missing {
                do {
                    try await StoreClient.installWithoutWine(client) { [weak self] text in
                        self?.storeClientDownload = text
                    }
                    AppLog.record("[store-setup] \(client.rawValue) installed without Wine")
                } catch {
                    let reason = (error as? StoreClient.InstallError)?.reason
                        ?? tr("Could not download the installer. Check the connection and try again.")
                    AppLog.record("[store-setup] \(client.rawValue) not installed: \(reason)")
                    self.storeClientError = "Execution Error: " + client.rawValue + ": " + reason
                    return
                }
            }
            StoreClient.prepareInstallEnvironment()
        }
    }
}
