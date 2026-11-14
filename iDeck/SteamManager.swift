import Foundation
import SwiftUI
import UIKit

// iDeck's Steam library models and helpers over Madeira's SwiftSteam backend (iDeck/SwiftSteam, verbatim).
#if os(iOS)

@MainActor
final class SteamOwnedGamesModel: ObservableObject {
    /// iDeck's one Steam library (the views and iRelay share it).
    static let shared = SteamOwnedGamesModel()

    @Published private(set) var games: [SteamAppInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installingApps: Set<UInt32> = []
    @Published private(set) var downloadProgress: [UInt32: SteamDownloadProgress] = [:]
    @Published private(set) var downloadErrors: [UInt32: String] = [:]
    @Published private(set) var installedApps: Set<UInt32> = []
    @Published private(set) var installedSizes: [UInt32: UInt64] = [:]
    /// The account's depot IDs (licenses), read once: a game's size counts the DLC
    /// depots among them, which the install downloads with the game.
    @Published private(set) var ownedDepotIDs: Set<UInt32> = []
    private var ownedDepotsRequested = false
    func loadOwnedDepots() {
        guard !ownedDepotsRequested, SteamSignIn.isSignedIn else { return }
        ownedDepotsRequested = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let owned = try? await self.fetcher.ownedDepotIDs() { self.ownedDepotIDs = owned }
            else { self.ownedDepotsRequested = false }
        }
    }
    private var installedSizeScanGeneration = 0
    @Published private(set) var availableDLC: [UInt32: [UInt32]] = [:]
    @Published private(set) var dlcMetadata: [UInt32: SteamAppInfo] = [:]
    @Published private(set) var installedDLC: [UInt32: Set<UInt32>] = [:]
    @Published private(set) var cancellingApps: Set<UInt32> = []
    @Published private(set) var pausedInstalls: Set<UInt32> = []
    private var stoppingPausedInstalls: Set<UInt32> = []
    @Published private(set) var installingDLC: [UInt32: UInt32] = [:]
    @Published private(set) var cancellingDLC: Set<UInt32> = []
    @Published private(set) var cloudMessages: [UInt32: String] = [:]
    @Published private(set) var cloudConflicts: Set<UInt32> = []
    @Published private(set) var cloudSyncing: Set<UInt32> = []

    private var installTasks: [UInt32: Task<Void, Never>] = [:]
    private var stopCleanupTasks: [UInt32: Task<Void, Never>] = [:]
    private var userPausedPrefixes: [UInt32: URL] = [:]
    private var dlcTasks: [UInt32: Task<Void, Never>] = [:]
    private var lastRefresh: Date?
    private var lastAccountName: String?
    private let session = SteamSession()
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private lazy var cloudEngine = SteamCloudSyncEngine(session: session)

    /// Display a lightweight cached library immediately while PICS refreshes.
    /// Cached preview entries contain no depot metadata: installing a game
    /// still requires fresh Steam metadata and authorization.
    /// Madeira Dock is about to sign Valve's client in: iDeck's own connection
    /// logs off and stays closed (no refresh, no reconnect) until `releaseDock()`.
    func holdForDock() async {
        await session.suspend()
        SteamLog.event("[dock-launch] iDeck's Steam connection logged off for the Dock session")
    }

    /// The Dock session ended (or its start failed): iDeck may connect again.
    func releaseDock() {
        session.resume()
    }

    func refresh(force: Bool = false) async {
        guard SteamSignIn.isSignedIn, let account = SteamSignIn.accountName,
              !account.isEmpty else {
            games = []
            lastAccountName = nil
            lastRefresh = nil
            errorMessage = nil
            return
        }
        guard !isLoading else { return }
        if lastAccountName != account {
            games = []
            lastRefresh = nil
            lastAccountName = account
        }
        if !force, !games.isEmpty, let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < 120 {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if games.isEmpty {
            let preview = await Task.detached(priority: .utility) {
                SteamLibraryPreviewCache.load(account: account)
            }.value
            guard SteamSignIn.accountName == account else { return }
            if let preview {
                games = preview.map { cached in
                    var app = SteamAppInfo(appID: cached.appID)
                    app.name = cached.name
                    app.type = SteamAppInfo.AppType(pics: cached.type)
                    app.installDir = cached.installDir
                    app.oslist = cached.oslist
                    app.buildID = cached.buildID
                    app.libraryCapsule = cached.libraryCapsule
                    app.libraryHero = cached.libraryHero
                    app.headerImage = cached.headerImage
                    app.parentID = cached.parentID
                    return app
                }
                SteamLog.event("[steam-library] loaded \(games.count) cached game previews")
            }
        }

        do {
            // The first connection after the app opens can time out while the
            // network (or LocalDevVPN) is still coming up; a reload then works.
            // One automatic retry after two seconds does that reload.
            let owned: [SteamAppInfo]
            do {
                owned = try await fetcher.fetchOwnedApps()
            } catch SteamError.connectionTimeout {
                SteamLog.event("[steam-library] connection timed out; retrying once")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                owned = try await fetcher.fetchOwnedApps()
            }
            let fresh = owned.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            guard SteamSignIn.accountName == account else { return }
            games = fresh
            lastRefresh = Date()
            lastAccountName = account
            let previews = fresh.map { game in
                SteamLibraryCachedGame(
                    appID: game.appID, name: game.name,
                    type: game.type.rawValue, installDir: game.installDir,
                    oslist: game.oslist, buildID: game.buildID,
                    libraryCapsule: game.libraryCapsule,
                    libraryHero: game.libraryHero,
                    headerImage: game.headerImage, parentID: game.parentID
                )
            }
            Task.detached(priority: .utility) {
                SteamLibraryPreviewCache.save(account: account, games: previews)
            }
        } catch {
            guard SteamSignIn.accountName == account else { return }
            errorMessage = SteamSignIn.message(error)
        }
    }

    func loadDLC(appID: UInt32) async {
        guard !Task.isCancelled else { return }
        do {
            let info: SteamAppInfo?
            if let cached = games.first(where: { $0.appID == appID }) {
                info = cached
            } else {
                info = try await fetcher.fetchInstallInfo(appID: appID)
            }
            guard let info else {
                availableDLC[appID] = []
                return
            }
            guard info.appID == appID else {
                availableDLC[appID] = []
                return
            }
            var found = Set(info.depots.compactMap { depot -> UInt32? in
                guard depot.publicManifestID != nil,
                      depot.supports(os: "windows"),
                      let dlc = depot.dlcAppID,
                      dlc != appID else { return nil }
                return dlc
            })
            // DLC the account owns that belong to this game but have no
            // downloadable depot of their own here (editions and upgrades such
            // as Skyrim's Anniversary content, or licence-only DLC).
            let listed = Set(info.knownDLC)
            for dlc in fetcher.ownedDLC where dlc.appID != appID &&
                (dlc.parentID == appID || listed.contains(dlc.appID)) {
                found.insert(dlc.appID)
                if dlcMetadata[dlc.appID] == nil { dlcMetadata[dlc.appID] = dlc }
            }
            let ids = found.sorted()
            availableDLC[appID] = ids
            for id in ids.prefix(256) where dlcMetadata[id] == nil {
                guard !Task.isCancelled else { return }
                if let details = try? await fetcher.fetchAppInfo(appID: id), details.appID == id {
                    guard !Task.isCancelled else { return }
                    dlcMetadata[id] = details
                }
            }
        } catch {
            if !Task.isCancelled { availableDLC[appID] = [] }
        }
    }

    func startInstall(appID: UInt32, prefixPath: URL) {
        guard installTasks[appID] == nil, !cancellingApps.contains(appID),
              !stoppingPausedInstalls.contains(appID) else { return }
        attachBackgroundDownloads()
        installPrefixes[appID] = prefixPath
        installTasks[appID] = Task { @MainActor in
            await self.install(appID: appID, prefixPath: prefixPath)
            self.installTasks.removeValue(forKey: appID)
            self.installPrefixes.removeValue(forKey: appID)
            self.cancellingApps.remove(appID)
        }
    }

    func canCancelInstall(appID: UInt32) -> Bool {
        installTasks[appID] != nil
    }

    /// A user pause keeps the Steam journal and all verified chunks on disk.
    func pauseInstall(appID: UInt32) {
        guard !stoppingPausedInstalls.contains(appID),
              let task = installTasks[appID], let prefix = installPrefixes[appID] else { return }
        userPausedPrefixes[appID] = prefix
        pausedInstalls.insert(appID)
        task.cancel()
    }

    func resumeInstall(appID: UInt32) {
        guard !stoppingPausedInstalls.contains(appID),
              let prefix = userPausedPrefixes[appID] else { return }
        let previous = installTasks[appID]
        Task { @MainActor in
            await previous?.value
            guard pausedInstalls.contains(appID) else { return }
            pausedInstalls.remove(appID)
            userPausedPrefixes.removeValue(forKey: appID)
            startInstall(appID: appID, prefixPath: prefix)
        }
    }

    func cancelInstall(appID: UInt32) {
        if let prefix = userPausedPrefixes.removeValue(forKey: appID) {
            stoppingPausedInstalls.insert(appID)
            cancellingApps.insert(appID)
            let previous = installTasks[appID]
            previous?.cancel()
            stopCleanupTasks[appID] = Task { @MainActor in
                await previous?.value
                pausedInstalls.remove(appID)
                if !isInstalled(appID: appID, prefixPath: prefix) {
                    let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
                    let steamApps = SteamInstallPaths.steamApps(drive: drive)
                    let owned = steamApps.appendingPathComponent("downloading/\(appID)/.ideck-owned-folder")
                    if let name = try? String(contentsOf: owned, encoding: .utf8),
                       !name.isEmpty, !name.contains("/"), !name.contains("\\") {
                        SteamInstallFiles.delete(appID: Int(appID), folderName: name, steamApps: steamApps)
                    } else {
                        try? FileManager.default.removeItem(
                            at: steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
                    }
                }
                downloadProgress.removeValue(forKey: appID)
                cancellingApps.remove(appID)
                stoppingPausedInstalls.remove(appID)
                stopCleanupTasks.removeValue(forKey: appID)
            }
            return
        }
        guard let task = installTasks[appID] else { return }
        cancellingApps.insert(appID)
        task.cancel()
    }

    /// A USB Stop response is returned only after file writes have stopped
    /// and the cancelled installation's owned temporary files were removed.
    func cancelInstallAndWait(appID: UInt32) async {
        let previous = installTasks[appID]
        cancelInstall(appID: appID)
        let cleanup = stopCleanupTasks[appID]
        await previous?.value
        await cleanup?.value
    }

    func startDLCInstall(appID: UInt32, dlcAppID: UInt32, prefixPath: URL) {
        guard dlcTasks[appID] == nil, !installingApps.contains(appID) else { return }
        installingDLC[appID] = dlcAppID
        dlcTasks[appID] = Task { @MainActor in
            await installDLC(appID: appID, dlcAppID: dlcAppID, prefixPath: prefixPath)
            dlcTasks.removeValue(forKey: appID)
            installingDLC.removeValue(forKey: appID)
            cancellingDLC.remove(dlcAppID)
        }
    }

    func cancelDLCInstall(appID: UInt32, dlcAppID: UInt32) {
        guard installingDLC[appID] == dlcAppID, let task = dlcTasks[appID] else { return }
        cancellingDLC.insert(dlcAppID)
        task.cancel()
    }

    func syncCloud(appID: UInt32, prefixPath: URL) async {
        guard !cloudSyncing.contains(appID), SteamSignIn.isSignedIn else { return }
        cloudSyncing.insert(appID)
        cloudMessages[appID] = "Sincronizando saves com a Steam..."
        defer { cloudSyncing.remove(appID) }
        do {
            guard let info = games.first(where: { $0.appID == appID }) else {
                throw SteamFileError.invalid("O jogo não está disponível na biblioteca Steam.")
            }
            let result = try await cloudEngine.sync(
                appID: appID, info: info, prefixPath: prefixPath)
            cloudMessages[appID] = result.message
            if result.conflicts > 0 {
                cloudConflicts.insert(appID)
            } else {
                cloudConflicts.remove(appID)
            }
        } catch {
            cloudMessages[appID] = "Steam Cloud: " + SteamSignIn.message(error)
        }
    }

    func resolveCloud(appID: UInt32, prefixPath: URL, preferCloud: Bool) async {
        guard !cloudSyncing.contains(appID), SteamSignIn.isSignedIn else { return }
        cloudSyncing.insert(appID)
        defer { cloudSyncing.remove(appID) }
        do {
            guard let info = games.first(where: { $0.appID == appID }) else {
                throw SteamFileError.invalid("O jogo não está disponível na biblioteca Steam.")
            }
            let result = try await cloudEngine.resolve(
                appID: appID, info: info, prefixPath: prefixPath, preferCloud: preferCloud)
            cloudMessages[appID] = result.message
            if result.conflicts == 0 { cloudConflicts.remove(appID) }
        } catch {
            cloudMessages[appID] = SteamSignIn.message(error)
        }
    }

    func refreshInstalledDLC(appID: UInt32, prefixPath: URL) {
        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        let ids = availableDLC[appID] ?? []
        installedDLC[appID] = Set(ids.filter {
            SteamDLCRecords.isInstalled(parentID: appID, dlcID: $0, steamApps: steamApps)
        })
    }

    func uninstallDLC(appID: UInt32, dlcAppID: UInt32, prefixPath: URL) -> Bool {
        guard availableDLC[appID]?.contains(dlcAppID) == true,
              !installingApps.contains(appID) else { return false }
        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        let removed = SteamDLCRecords.uninstall(parentID: appID, dlcID: dlcAppID,
                                                 steamApps: steamApps)
        refreshInstalledDLC(appID: appID, prefixPath: prefixPath)
        return removed
    }

    func refreshInstalledApps(prefixPath: URL) {
        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: steamApps.path)) ?? []
        installedApps = Set(names.compactMap { filename -> UInt32? in
            guard filename.hasPrefix("appmanifest_"), filename.hasSuffix(".acf") else { return nil }
            return UInt32(filename.dropFirst("appmanifest_".count).dropLast(4))
        })
        installedSizes = installedSizes.filter { installedApps.contains($0.key) }
        installedSizeScanGeneration += 1
        let generation = installedSizeScanGeneration
        let appIDs = installedApps
        Task { [weak self] in
            let measured = await Task.detached(priority: .utility) {
                var sizes: [UInt32: UInt64] = [:]
                for id in appIDs {
                    guard let folder = SteamInstallFiles.installDirectoryName(
                        appID: Int(id), steamApps: steamApps) else { continue }
                    let location = steamApps.appendingPathComponent("common", isDirectory: true)
                        .appendingPathComponent(folder, isDirectory: true)
                    if let bytes = SteamInstallFiles.logicalInstalledSize(at: location) {
                        sizes[id] = bytes
                    }
                }
                return sizes
            }.value
            guard let self,
                  self.installedSizeScanGeneration == generation,
                  self.installedApps == appIDs else { return }
            self.installedSizes = measured
        }
    }

    func isInstalled(appID: UInt32, prefixPath: URL) -> Bool {
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        return SteamInstallFiles.buildID(appID: Int(appID), steamApps: steamApps) != nil
    }

    func uninstall(appID: UInt32, prefixPath: URL) -> Bool {
        guard let app = games.first(where: { $0.appID == appID }),
              !app.installDir.isEmpty else {
            downloadErrors[appID] = "Steam install metadata is missing. Refresh the library before uninstalling."
            return false
        }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        SteamInstallFiles.delete(appID: Int(appID), folderName: app.installDir, steamApps: steamApps)
        installedApps.remove(appID)
        installedSizes.removeValue(forKey: appID)
        downloadProgress.removeValue(forKey: appID)
        installingApps.remove(appID)
        downloadErrors.removeValue(forKey: appID)
        return !isInstalled(appID: appID, prefixPath: prefixPath)
    }

    func install(appID: UInt32, prefixPath: URL) async {
        guard !installingApps.contains(appID) else { return }
        if AntiCheatPolicy.isBlocked(title: games.first(where: { $0.appID == appID })?.name ?? "", steamAppID: appID) {
            downloadErrors[appID] = AntiCheatPolicy.message
            return
        }
        guard SteamSignIn.isSignedIn else {
            downloadErrors[appID] = "Sign in to install Steam games."
            return
        }
        installingApps.insert(appID)
        downloadErrors[appID] = nil
        downloadProgress[appID] = SteamDownloadProgress()
        let displayName = games.first(where: { $0.appID == appID })?.name ?? "App \(appID)"
        // Record installation context before running Wine or any Windows game.
        // Diagnostic reports must name the Steam title even if iOS stops
        // the app during a download, before the executable has launched.
        UserDefaults.standard.set(String(displayName.prefix(160)), forKey: "diagnostics.lastGame")
        UserDefaults.standard.set("Steam", forKey: "diagnostics.lastLauncher")
        // This marker survives a process termination that cannot run defer.
        // It is diagnostic only: never delete journals or staging files.
        UserDefaults.standard.set("\(appID)|" + String(displayName.prefix(160)),
                                  forKey: "diagnostics.installInFlight")
        AppLog.record("[steam-install] started app=\(appID) game=\(displayName)")
        BackgroundDownloads.steam.started(name: displayName)
        BenchmarkSession.begin(kind: "install", scenario: "Steam: " + displayName,
                               settings: ["store": "steam", "reinstall": isInstalled(appID: appID, prefixPath: prefixPath)])
        var outcome = BackgroundDownloads.Outcome.paused
        defer {
            if UserDefaults.standard.string(forKey: "diagnostics.installInFlight")?.hasPrefix("\(appID)|") == true {
                UserDefaults.standard.removeObject(forKey: "diagnostics.installInFlight")
            }
            installingApps.remove(appID)
            BackgroundDownloads.steam.ended(name: displayName, outcome: outcome,
                                            queueEmpty: installingApps.isEmpty)
            let benchmarkOutcome: String
            switch outcome {
            case .completed: benchmarkOutcome = "completed"
            case .failed(let message): benchmarkOutcome = "failed: " + message
            default: benchmarkOutcome = "paused"
            }
            BenchmarkSession.finish(kind: "install", outcome: benchmarkOutcome,
                                    installBytes: installedSizes[appID] ?? 0)
        }
        var installFolder: String?
        var installFolderAlreadyExisted = false
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        let steamApps = SteamInstallPaths.steamApps(drive: drive)
        let wasInstalled = isInstalled(appID: appID, prefixPath: prefixPath)
        let installOwnership = steamApps.appendingPathComponent(
            "downloading/\(appID)/.ideck-owned-folder", isDirectory: false)
        var ownsIncompleteInstall = false
        do {
            try Task.checkCancellation()
            guard let app = try await fetcher.fetchInstallInfo(appID: appID) else {
                throw SteamError.depotNotFound(appID)
            }
            installFolder = SteamInstallFiles.safeFolderName(
                app.installDir.isEmpty ? "app_\(app.appID)" : app.installDir)
            if let installFolder {
                installFolderAlreadyExisted = FileManager.default.fileExists(atPath:
                    steamApps.appendingPathComponent("common", isDirectory: true)
                        .appendingPathComponent(installFolder, isDirectory: true).path)
            }
            guard app.installableOnWindows else {
                throw SteamError.depotNotFound(appID)
            }
            // Only claim ownership of a directory that did not exist before
            // this install. Retain the marker across failed/resumed downloads
            // so cancelling a later retry can remove the incomplete game.
            let savedOwner = try? String(contentsOf: installOwnership, encoding: .utf8)
            ownsIncompleteInstall = !wasInstalled &&
                (savedOwner == installFolder ||
                 (!installFolderAlreadyExisted && installFolder != nil))
            if ownsIncompleteInstall && !installFolderAlreadyExisted,
               let installFolder {
                try FileManager.default.createDirectory(
                    at: installOwnership.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try installFolder.write(to: installOwnership, atomically: true, encoding: .utf8)
            }
            try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
            if !wasInstalled, !installFolderAlreadyExisted, let installFolder {
                ExternalDrives.shared.prepareExternalInstall(
                    local: SteamInstallPaths.common(drive: drive).appendingPathComponent(installFolder, isDirectory: true),
                    store: "Steam")
            }
            _ = try await downloader.install(
                app,
                steamApps: steamApps,
                ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() },
                progress: { [weak self] progress in
                    self?.downloadProgress[appID] = progress
                    BackgroundDownloads.steam.progress(done: progress.doneBytes, total: progress.totalBytes)
                }
            )
            try Task.checkCancellation()
            outcome = .completed
            installedApps.insert(appID)
            if let measuredSize = downloadProgress[appID]?.installedBytes, measuredSize > 0 {
                installedSizes[appID] = measuredSize
            }
            downloadErrors[appID] = nil
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            if cancelled, pausedForBackground[appID] != nil {
                // Paused by iOS: keep every journaled chunk for the resume.
                downloadProgress.removeValue(forKey: appID)
                downloadErrors[appID] = nil
                return
            }
            if cancelled, pausedInstalls.contains(appID) {
                // User pause: preserve progress and partial files until Resume or Stop.
                downloadErrors[appID] = nil
                return
            }
            if !cancelled { outcome = .failed(SteamSignIn.message(error)) }
            if cancelled, !wasInstalled {
                if ownsIncompleteInstall, let installFolder {
                    SteamInstallFiles.delete(appID: Int(appID), folderName: installFolder,
                                             steamApps: steamApps)
                } else {
                    // This directory predated iDeck's ownership marker.
                    // Never remove potentially unrelated user files.
                    try? FileManager.default.removeItem(at:
                        steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
                }
            }
            downloadProgress.removeValue(forKey: appID)
            downloadErrors[appID] = cancelled ? nil : SteamSignIn.message(error)
        }
    }

    func installDLC(appID: UInt32, dlcAppID: UInt32, prefixPath: URL) async {
        guard isInstalled(appID: appID, prefixPath: prefixPath) else {
            downloadErrors[appID] = "Install this game before installing its DLC."
            return
        }
        guard !installingApps.contains(appID) else { return }
        guard SteamSignIn.isSignedIn else {
            downloadErrors[appID] = "Sign in to install Steam games."
            return
        }
        installingApps.insert(appID)
        downloadErrors[appID] = nil
        downloadProgress[appID] = SteamDownloadProgress()
        let dlcName = dlcMetadata[dlcAppID]?.name ?? "DLC \(dlcAppID)"
        BackgroundDownloads.steam.started(name: dlcName)
        var outcome = BackgroundDownloads.Outcome.paused
        defer {
            installingApps.remove(appID)
            BackgroundDownloads.steam.ended(name: dlcName, outcome: outcome,
                                            queueEmpty: installingApps.isEmpty)
        }
        do {
            try Task.checkCancellation()
            // iRelay can ask before the game's page loaded its DLC list.
            if availableDLC[appID] == nil { await loadDLC(appID: appID) }
            guard let app = try await fetcher.fetchInstallInfo(appID: appID),
                  app.appID == appID,
                  app.installableOnWindows,
                  availableDLC[appID]?.contains(dlcAppID) == true else {
                throw SteamError.depotNotFound(dlcAppID)
            }
            let steamApps = SteamInstallPaths.steamApps(
                drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
            // A DLC with no files of its own (a licence that unlocks content the
            // game already has) is installed as soon as it is recorded.
            guard app.depots.contains(where: {
                $0.dlcAppID == dlcAppID && $0.publicManifestID != nil && $0.supports(os: "windows")
            }) else {
                try SteamDLCRecords.markInstalled(parentID: appID, dlcID: dlcAppID, files: [], steamApps: steamApps)
                outcome = .completed
                downloadProgress.removeValue(forKey: appID)
                refreshInstalledDLC(appID: appID, prefixPath: prefixPath)
                return
            }
            try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
            _ = try await downloader.install(app, steamApps: steamApps,
                ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() },
                onlyDLC: [dlcAppID],
                progress: { [weak self] progress in
                    self?.downloadProgress[appID] = progress
                    BackgroundDownloads.steam.progress(done: progress.doneBytes, total: progress.totalBytes)
                })
            try Task.checkCancellation()
            outcome = .completed
            installedApps.insert(appID)
            downloadProgress.removeValue(forKey: appID)
            refreshInstalledDLC(appID: appID, prefixPath: prefixPath)
        } catch {
            if Task.isCancelled || error is CancellationError {
                downloadErrors[appID] = nil
                downloadProgress.removeValue(forKey: appID)
            } else {
                outcome = .failed(SteamSignIn.message(error))
                downloadErrors[appID] = SteamSignIn.message(error)
            }
        }
    }

    // MARK: Background pause and resume

    /// Games paused because iOS ended iDeck's background time, with their prefix.
    private var pausedForBackground: [UInt32: URL] = [:]
    private var installPrefixes: [UInt32: URL] = [:]
    private var backgroundAttached = false

    private func attachBackgroundDownloads() {
        guard !backgroundAttached else { return }
        backgroundAttached = true
        BackgroundDownloads.steam.attach(
            active: { [weak self] in !(self?.installTasks.isEmpty ?? true) },
            pause: { [weak self] in self?.pauseForBackground() },
            resume: { [weak self] in self?.resumeAfterBackground() })
    }

    private func pauseForBackground() {
        for (appID, task) in installTasks {
            guard !pausedInstalls.contains(appID), let prefix = installPrefixes[appID] else { continue }
            pausedForBackground[appID] = prefix
            task.cancel()
        }
    }

    private func resumeAfterBackground() {
        let paused = pausedForBackground
        guard !paused.isEmpty else { return }
        Task { @MainActor in
            // Let the cancelled tasks unwind before starting again.
            for _ in 0..<50 where paused.keys.contains(where: { installTasks[$0] != nil }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            for (appID, prefix) in paused {
                pausedForBackground.removeValue(forKey: appID)
                startInstall(appID: appID, prefixPath: prefix)
            }
        }
    }

    func disconnect() {
        stoppingPausedInstalls.removeAll()
        pausedInstalls.removeAll()
        userPausedPrefixes.removeAll()
        for task in dlcTasks.values { task.cancel() }
        dlcTasks.removeAll()
        installingDLC.removeAll()
        cancellingDLC.removeAll()
        cloudMessages.removeAll()
        cloudConflicts.removeAll()
        for task in installTasks.values { task.cancel() }
        installTasks.removeAll()
        lastRefresh = nil
        lastAccountName = nil
        availableDLC.removeAll()
        installedDLC.removeAll()
        installedSizes.removeAll()
        installedSizeScanGeneration += 1
        dlcMetadata.removeAll()
        games = []
        errorMessage = nil
        downloadErrors = [:]
        Task { await session.disconnectGracefully() }
    }
}
#endif


import Foundation

class SteamManager {
    func applySteamRegistryFixes(prefixPath: String) {
        let registryPath = prefixPath + "/user.reg"
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: registryPath) else { return }
        
        do {
            var registryContent = try String(contentsOfFile: registryPath, encoding: .utf8)
            
            let overrides = """
            
            [Software\\\\Wine\\\\AppDefaults\\\\steam.exe\\\\DllOverrides]
            "dwrite"="d"
            "winhttp"="n,b"
            "crypt32"="n,b"
            "secur32"="n,b"
            
            [Software\\\\Valve\\\\Steam]
            "DWriteEnable"="0"
            "CEFDisableGPU"="1"
            "SmoothScrollWebviews"="0"
            
            """
            
            if !registryContent.contains("AppDefaults\\\\steam.exe") {
                registryContent.append(overrides)
                try registryContent.write(toFile: registryPath, atomically: true, encoding: .utf8)
            }
        } catch {
            print("SteamManager: Registry override failed.")
        }
    }
}
