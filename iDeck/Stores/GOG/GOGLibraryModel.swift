// GOGLibraryModel.swift
// Split from GOGLibrary.swift (iDeck 3.0 architecture).

import Foundation
import SwiftUI

@MainActor
final class GOGLibraryModel: ObservableObject {
    static let shared = GOGLibraryModel()

    @Published private(set) var isSignedIn = GOGTokenStore.load() != nil
    @Published private(set) var username: String? { didSet { PrivacyRedactor.register(username) } }
    @Published private(set) var games: [GOGGame] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installed: [Int: GOGInstalledGame] = [:]
    @Published private(set) var downloadProgress: [Int: Double] = [:]
    @Published private(set) var downloadErrors: [Int: String] = [:]
    @Published private(set) var downloadETASeconds: [Int: Int] = [:]
    /// Bytes downloaded and to download for each game being installed (the details page).
    @Published private(set) var downloadedBytes: [Int: (done: UInt64, total: UInt64)] = [:]
    private var transferRateSamples: [Int: (at: Date, bytes: UInt64, rate: Double)] = [:]

    private func updateDownloadETA(gameID: Int, done: UInt64, total: UInt64) {
        guard total > 0, done < total else {
            downloadETASeconds.removeValue(forKey: gameID)
            return
        }
        let now = Date()
        guard let previous = transferRateSamples[gameID] else {
            transferRateSamples[gameID] = (now, done, 0)
            return
        }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed >= 1.0 else { return }
        let currentRate = done > previous.bytes ? Double(done - previous.bytes) / elapsed : 0
        let smoothed = previous.rate > 0 && currentRate > 0
            ? 0.65 * previous.rate + 0.35 * currentRate : currentRate
        transferRateSamples[gameID] = (now, done, smoothed)
        downloadETASeconds[gameID] = DownloadETA.seconds(done: done, total: total,
                                                         bytesPerSecond: smoothed)
    }

    private func resetDownloadETA(gameID: Int) {
        downloadedBytes.removeValue(forKey: gameID)
        transferRateSamples.removeValue(forKey: gameID)
        downloadETASeconds.removeValue(forKey: gameID)
    }

    @Published private(set) var pausedDownloads: Set<Int> = []
    /// Install size of each game's Galaxy build, from GOG; 0 = unknown.
    @Published private(set) var downloadSizes: [Int: Int64] = [:]
    /// Size on disk of installed games, measured from their install folder.
    @Published private(set) var installedSizes: [Int: Int64] = [:]

    /// Fetches the Galaxy build size for the game details page (once).
    func loadSize(for game: GOGGame) async {
        if let folder = installed[game.id]?.executable.deletingLastPathComponent(), installedSizes[game.id] == nil {
            let root = Self.installFolder(containing: folder)
            let bytes = await Task.detached(priority: .utility) { Self.folderSize(root) }.value
            if bytes > 0 { installedSizes[game.id] = bytes }
        }
        guard downloadSizes[game.id] == nil, let tokens = try? await tokens() else { return }
        if let plan = try? await GOGContentSystem.plan(gameID: game.id, tokens: tokens) {
            downloadSizes[game.id] = plan.installBytes
        }
    }

    enum InstallOutcome {
        /// The game's files are in C:\GOG Games\<folder>.
        case installed
        case failed
    }

    /// Installs a game the way GOG Galaxy does: every file of the newest
    /// Windows build is downloaded from GOG's content system straight into
    /// C:\GOG Games\<installDirectory>. Nothing runs in Wine. Only GOG
    /// Galaxy builds are installed; no offline installer is used.
    func install(_ game: GOGGame, prefixPath: URL, completion: @escaping (InstallOutcome) -> Void) {
        guard downloadTasks[game.id] == nil else { return }
        if AntiCheatPolicy.isBlocked(title: game.title) {
            downloadErrors[game.id] = AntiCheatPolicy.message
            completion(.failed)
            return
        }
        pausedDownloads.remove(game.id)
        resumeDownloads[game.id] = { [weak self] in self?.install(game, prefixPath: prefixPath, completion: completion) }
        downloadPrefixes[game.id] = prefixPath
        downloadErrors[game.id] = nil
        downloadProgress[game.id] = 0
        resetDownloadETA(gameID: game.id)
        let games = prefixPath.appendingPathComponent("drive_c/GOG Games", isDirectory: true)
        BackgroundDownloads.gog.attach(active: { [weak self] in !(self?.downloadTasks.isEmpty ?? true) },
                                       pause: {}, resume: {})
        BackgroundDownloads.gog.started(name: game.title)
        downloadTasks[game.id] = Task {
            var outcome = BackgroundDownloads.Outcome.paused
            defer {
                resetDownloadETA(gameID: game.id)
                downloadTasks[game.id] = nil
                if !pausedDownloads.contains(game.id) { downloadProgress[game.id] = nil }
                BackgroundDownloads.gog.ended(name: game.title, outcome: outcome, queueEmpty: downloadTasks.isEmpty)
                if !pausedDownloads.contains(game.id) { resumeDownloads.removeValue(forKey: game.id) }
            }
            do {
                let tokens = try await tokens()
                let plan: GOGContentPlan
                do {
                    plan = try await GOGContentSystem.plan(gameID: game.id, tokens: tokens)
                } catch GOGContentError.noBuild {
                    throw GOGError.noGalaxyBuild
                }
                let name = GOGContentSystem.safePath(plan.installDirectory)?.replacingOccurrences(of: "/", with: " ")
                    ?? "Game \(game.id)"
                let staging = games.appendingPathComponent(".downloading/\(name)", isDirectory: true)
                stagingFolders[game.id] = staging
                let final = games.appendingPathComponent(name, isDirectory: true)
                let total = max(plan.downloadBytes, 1)
                downloadSizes[game.id] = plan.installBytes
                let counter = GOGByteCounter()
                AppLog.record("[gog] installing game \(game.id): \(plan.files.count) files, \(plan.downloadBytes) bytes to download")
                let installer = GOGContentInstaller(tokens: tokens) { bytes in
                    // At most every 0.5 s (and at once when finished); the main-actor guard
                    // below drops reports that arrive out of order.
                    let done = counter.add(bytes)
                    guard ProgressThrottle.allow("gog:\(game.id)", done: UInt64(max(done, 0)), total: UInt64(total)) else { return }
                    Task { @MainActor in
                        guard UInt64(max(done, 0)) >= (self.downloadedBytes[game.id]?.done ?? 0) else { return }
                        self.downloadProgress[game.id] = min(Double(done) / Double(total), 1)
                        self.downloadedBytes[game.id] = (UInt64(max(done, 0)), UInt64(total))
                        self.updateDownloadETA(gameID: game.id, done: UInt64(max(done, 0)), total: UInt64(total))
                        BackgroundDownloads.gog.progress(done: UInt64(done), total: UInt64(total))
                    }
                }
                try await installer.install(plan, into: staging)
                let manager = FileManager.default
                if manager.fileExists(atPath: final.path) {
                    // Merge into an existing folder (an update or an earlier installer).
                    let walker = manager.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey])
                    while let item = walker?.nextObject() as? URL {
                        guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                        let relative = String(item.standardizedFileURL.path.dropFirst(staging.standardizedFileURL.path.count + 1))
                        let target = final.appendingPathComponent(relative)
                        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? manager.removeItem(at: target)
                        try manager.moveItem(at: item, to: target)
                    }
                    try? manager.removeItem(at: staging)
                } else {
                    try manager.moveItem(at: staging, to: final)
                }
                // Install script and redistributables, used before each start (GOGLaunchServices).
                GOGLaunchServices.record(plan, folder: final)
                AppLog.record("[gog] game \(game.id) installed into C:\\GOG Games\\\(name)")
                outcome = .completed
                refreshInstalled(prefixPath: prefixPath)
                completion(.installed)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    completion(.failed)
                } else {
                    downloadErrors[game.id] = error.localizedDescription
                    outcome = .failed(error.localizedDescription)
                    AppLog.record("[gog] install failed for game \(game.id): \(error.localizedDescription)")
                    // What was downloaded is removed, as Stop does: no half game is left.
                    if let staging = stagingFolders.removeValue(forKey: game.id) {
                        try? FileManager.default.removeItem(at: staging)
                        AppLog.record("[gog] game \(game.id): partial files removed")
                    }
                    completion(.failed)
                }
            }
        }
    }

    /// The game's own folder: the highest folder up from the program that
    /// still holds a goggame-*.info file, otherwise the program's folder.
    nonisolated static func installFolder(containing folder: URL) -> URL {
        var best = folder
        var current = folder
        for _ in 0..<4 {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            if names.contains(where: { $0.hasPrefix("goggame-") && $0.hasSuffix(".info") }) { best = current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return best
    }

    nonisolated static func folderSize(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    private var downloadTasks: [Int: Task<Void, Never>] = [:]
    private var resumeDownloads: [Int: () -> Void] = [:]
    private var stagingFolders: [Int: URL] = [:]
    private var cancellationCleanup: [Int: Task<Void, Never>] = [:]
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iDeck-gog-library.json")

    private init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([GOGGame].self, from: data) {
            games = cached
        }
    }

    /// A valid access token, refreshed when it has expired.
    func tokens() async throws -> GOGTokens {
        guard let stored = GOGTokenStore.load() else {
            isSignedIn = false
            throw GOGError.notSignedIn
        }
        guard stored.isExpired else { return stored }
        do {
            let fresh = try await GOGAPI.refresh(stored)
            GOGTokenStore.save(fresh)
            return fresh
        } catch GOGError.signInRejected {
            signOut()
            throw GOGError.notSignedIn
        }
    }

    func completeSignIn(code: String) async throws {
        let tokens = try await GOGAPI.exchange(code: code)
        GOGTokenStore.save(tokens)
        isSignedIn = true
        AppLog.record("[gog] signed in")
        await refresh()
    }

    func signOut() {
        GOGTokenStore.delete()
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        downloadProgress.removeAll()
        isSignedIn = false
        username = nil
        games = []
        try? FileManager.default.removeItem(at: cacheURL)
        AppLog.record("[gog] signed out")
    }

    func refresh() async {
        guard isSignedIn, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let tokens = try await tokens()
            async let owned = GOGAPI.ownedGames(tokens: tokens)
            async let name = GOGAPI.username(tokens: tokens)
            games = try await owned
            username = await name
            if let data = try? JSONEncoder().encode(games) { try? data.write(to: cacheURL, options: .atomic) }
        } catch {
            errorMessage = error.localizedDescription
            AppLog.record("[gog] library refresh failed: \(error.localizedDescription)")
        }
    }

    func refreshInstalled(prefixPath: URL?) {
        guard let prefixPath else { installed = [:]; return }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        Task {
            installed = await Task.detached(priority: .utility) {
                GOGInstallScanner.installed(in: drive)
            }.value
        }
    }

    /// Deletes an installed game's folder (the one holding its goggame-*.info
    /// file) and rescans. Refuses folders that are not inside drive_c.
    @discardableResult
    func uninstall(_ gameID: Int, prefixPath: URL) -> Bool {
        guard let game = installed[gameID] else { return false }
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let folder = Self.installFolder(containing: game.executable.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL
        guard folder.path.hasPrefix(drive + "/"), folder.pathComponents.count > drive.split(separator: "/").count + 2 else { return false }
        do { try FileManager.default.removeItem(at: folder) } catch { return false }
        installed[gameID] = nil
        installedSizes[gameID] = nil
        refreshInstalled(prefixPath: prefixPath)
        return true
    }

    /// Wide artwork for a game's details page, best first.
    static func bannerCandidates(_ game: GOGGame) -> [URL] {
        guard let image = game.image, !image.isEmpty else { return [] }
        let base = image.hasPrefix("//") ? "https:" + image : image
        return ["_glx_bg_top_padding_7.webp", "_bg_crop_1366x655.jpg", "_product_card_v2_mobile_slider_639.jpg"]
            .compactMap { URL(string: base + $0) }
    }

    /// Pause cancels network activity while retaining GOG's staged files.
    /// The Windows prefix each download installs into, so Stop can uninstall it.
    private var downloadPrefixes: [Int: URL] = [:]

    func pauseDownload(_ game: GOGGame) {
        guard let task = downloadTasks[game.id] else { return }
        pausedDownloads.insert(game.id)
        task.cancel()
    }

    func resumeDownload(_ game: GOGGame) {
        guard pausedDownloads.contains(game.id) else { return }
        let previous = downloadTasks[game.id]
        Task { @MainActor in
            await previous?.value
            guard pausedDownloads.contains(game.id) else { return }
            pausedDownloads.remove(game.id)
            resumeDownloads[game.id]?()
        }
    }

    func cancelDownload(_ game: GOGGame) {
        let previous = downloadTasks[game.id]
        previous?.cancel()
        pausedDownloads.remove(game.id)
        resumeDownloads.removeValue(forKey: game.id)
        cancellationCleanup[game.id] = Task { @MainActor in
            await previous?.value
            if let staging = stagingFolders.removeValue(forKey: game.id) {
                try? FileManager.default.removeItem(at: staging)
            }
            // Stop download uninstalls: an installed game being updated goes too.
            if let prefix = downloadPrefixes.removeValue(forKey: game.id) {
                refreshInstalled(prefixPath: prefix)
                if installed[game.id] != nil { uninstall(game.id, prefixPath: prefix) }
            }
            downloadErrors.removeValue(forKey: game.id)
            downloadProgress.removeValue(forKey: game.id)
            cancellationCleanup.removeValue(forKey: game.id)
        }
    }

    func cancelDownloadAndWait(_ game: GOGGame) async {
        cancelDownload(game)
        let cleanup = cancellationCleanup[game.id]
        await cleanup?.value
    }
}
