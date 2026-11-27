// StoreProvider.swift
// iDeck 3.0.1: one interface over Steam, GOG, Epic Games, the EA app and Ubisoft Connect.

import Foundation

/// A game of a store, as every store names it: the store and its own id (Steam app id,
/// GOG game id, Epic app name, EA offer id, Ubisoft product key) and its title.
struct StoreGameRef: Hashable, Sendable {
    let store: GameStore
    let id: String
    let title: String
}

/// Where a store's download of a game stands, whatever the store.
enum StoreDownloadState: Equatable, Sendable {
    case queued
    case active(Double)
    case paused
    case failed(String)

    /// A download that is using the network and the disk right now (or about to).
    var isRunning: Bool {
        switch self {
        case .queued, .active: return true
        case .paused, .failed: return false
        }
    }
}

/// Everything a screen shows about a download, whatever the store.
struct StoreDownloadStatus: Equatable, Sendable {
    /// Where an install is inside its download, as every store's downloader names it.
    enum Phase: Equatable, Sendable { case preparing, verifying, downloading, finishing }

    var state: StoreDownloadState
    var doneBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var phase: Phase = .downloading
    /// Bytes are moving (the downloading phase, not preparing, verifying or finishing).
    var transferring: Bool { phase == .downloading }
    /// How far the check of files already on disk is (verifying), when the store says.
    var verifyFraction: Double?
    /// Bytes of the game written so far (Steam counts them apart from the download).
    var writtenBytes: UInt64 = 0
    var etaSeconds: Int?
    /// Queued behind another download of the same store.
    var waiting = false
    /// A stop is removing the files.
    var stopping = false
    /// Pause and Stop apply now.
    var cancellable = false
    /// What the store is doing before bytes move ("Reading the manifest…"), when it says.
    var step: String?

    var failure: String? { if case .failed(let message) = state { return message }; return nil }
    var isPaused: Bool { state == .paused }
    /// The bar's value: nil once the download failed.
    var progress: Double? {
        switch state {
        case .active(let fraction): return fraction
        case .queued, .paused: return totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0
        case .failed: return nil
        }
    }
}

/// A DLC of a game, whatever the store: its id in the store (Steam DLC app id, Epic
/// DLC app name), its title, its picture when the store gives one, and its size.
struct StoreDLC: Hashable, Sendable {
    let id: String
    let title: String
    var image: URL?
    var sizeBytes: UInt64?
}

/// What every store offers iDeck. Each store keeps its own model (sign-in, manifests,
/// downloader); the provider is the common face that the library, the bug report and
/// the resource governor use instead of asking each store in its own words.
/// `prefix` is the mounted Windows prefix: Steam and GOG install into it, the others
/// into Madeira's drive.
@MainActor
protocol StoreProvider: AnyObject {
    var store: GameStore { get }
    var name: String { get }
    var isSignedIn: Bool { get }
    var ownedGames: [StoreGameRef] { get }
    func isInstalled(_ id: String, prefix: URL?) -> Bool
    /// The installed games' ids, from the store's published state (no disk check).
    var installedIDs: Set<String> { get }
    /// The ids of every game with a download state (running, paused or failed), owned
    /// list or not.
    var downloadIDs: Set<String> { get }
    func downloadStatus(_ id: String) -> StoreDownloadStatus?
    /// Starts or queues the install, or the update of an installed game (a language's
    /// files, a new build); false when the store cannot do it now (no prefix, unknown
    /// game). `onFinish` runs when the store reports the end of the install (GOG); the
    /// other stores publish it through their own state, which the screens observe.
    @discardableResult func install(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)?) -> Bool
    func pause(_ id: String)
    func resume(_ id: String, prefix: URL?)
    /// Stops the download and removes what it wrote.
    func cancel(_ id: String)
    /// Removes an installed game; false when the store cannot (or it is not installed).
    @discardableResult func uninstall(_ id: String, prefix: URL?) -> Bool
    func refresh() async

    // DLC (3.0.1). Stores without DLC in iDeck (GOG, the EA app, Ubisoft Connect) keep
    // the empty answers of the extension below.
    var supportsDLC: Bool { get }
    /// The game's DLC the account can install, in the store's order.
    func dlcs(of gameID: String) -> [StoreDLC]
    func isDLCInstalled(_ dlcID: String, of gameID: String) -> Bool
    func dlcDownloadStatus(_ dlcID: String, of gameID: String) -> StoreDownloadStatus?
    @discardableResult func installDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool
    func cancelDLC(_ dlcID: String, of gameID: String)
    @discardableResult func uninstallDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool
    /// Asks the store for the game's DLC list and which of them are installed.
    func loadDLC(of gameID: String, prefix: URL?) async
    /// Reads which DLC are installed again (after a DLC install ended), without the list.
    func refreshInstalledDLC(of gameID: String, prefix: URL)
    /// The DLC being installed for the game now, if any.
    func installingDLC(of gameID: String) -> String?
}

extension StoreProvider {
    var supportsDLC: Bool { false }
    func dlcs(of gameID: String) -> [StoreDLC] { [] }
    func isDLCInstalled(_ dlcID: String, of gameID: String) -> Bool { false }
    func dlcDownloadStatus(_ dlcID: String, of gameID: String) -> StoreDownloadStatus? { nil }
    @discardableResult func installDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool { false }
    func cancelDLC(_ dlcID: String, of gameID: String) {}
    @discardableResult func uninstallDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool { false }
    func loadDLC(of gameID: String, prefix: URL?) async {}
    func refreshInstalledDLC(of gameID: String, prefix: URL) {}
    func installingDLC(of gameID: String) -> String? {
        dlcs(of: gameID).first { dlcDownloadStatus($0.id, of: gameID) != nil }?.id
    }

    @discardableResult func install(_ id: String, prefix: URL?) -> Bool { install(id, prefix: prefix, onFinish: nil) }

    func downloadState(_ id: String) -> StoreDownloadState? { downloadStatus(id)?.state }

    /// A download is under way or paused (not only failed).
    func hasDownload(_ id: String) -> Bool {
        guard let state = downloadState(id) else { return false }
        if case .failed = state { return false }
        return true
    }

    /// The games of this store with a download under way or paused, in the store's order.
    var gamesWithDownloads: [StoreGameRef] { ownedGames.filter { hasDownload($0.id) } }

    /// Installed games and games with a download, owned list or not.
    var installedOrDownloadingIDs: Set<String> { installedIDs.union(downloadIDs) }

    /// Install, or resume a paused download: what a page's Install button does.
    func installOrResume(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)? = nil) {
        if downloadState(id) == .paused { resume(id, prefix: prefix) } else { install(id, prefix: prefix, onFinish: onFinish) }
    }

    /// Every download of this store that has a state, with its game.
    var downloads: [(game: StoreGameRef, state: StoreDownloadState)] {
        let titles = Dictionary(ownedGames.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return downloadIDs.sorted().compactMap { id in
            downloadState(id).map { (StoreGameRef(store: store, id: id, title: titles[id] ?? id), $0) }
        }
    }
}

/// The five providers, and what iDeck asks of all stores at once.
@MainActor
enum StoreProviders {
    static let all: [any StoreProvider] = [SteamStoreProvider(), GOGStoreProvider(), EpicStoreProvider(),
                                           EAStoreProvider(), UbisoftStoreProvider()]

    static func provider(_ store: GameStore) -> (any StoreProvider)? { all.first { $0.store == store } }

    /// The provider of a store; every store has one.
    static func of(_ store: GameStore) -> any StoreProvider {
        guard let provider = provider(store) else { preconditionFailure("no StoreProvider for \(store)") }
        return provider
    }

    /// Downloads that are running or queued, in every store.
    static var runningDownloads: [(game: StoreGameRef, state: StoreDownloadState)] {
        all.flatMap { provider in provider.downloads.filter { $0.state.isRunning } }
    }

    static var anyDownloadRunning: Bool { all.contains { provider in provider.downloads.contains { $0.state.isRunning } } }

    /// Pauses every running download; returns the games paused, to resume them later.
    @discardableResult
    static func pauseAll() -> [StoreGameRef] {
        let running = runningDownloads.map(\.game)
        for game in running { provider(game.store)?.pause(game.id) }
        if !running.isEmpty {
            AppLog.record("[stores] paused \(running.count) download(s): " + running.map { "\($0.store)" }.joined(separator: ", "))
        }
        return running
    }

    static func resume(_ games: [StoreGameRef], prefix: URL?) {
        for game in games { provider(game.store)?.resume(game.id, prefix: prefix) }
    }

    /// One line per store for the bug report: signed in, games owned, downloads.
    static var summary: [String] {
        all.map { provider in
            let downloads = provider.downloads
            let running = downloads.filter { $0.state.isRunning }.count
            let paused = downloads.filter { $0.state == .paused }.count
            let failed = downloads.filter { if case .failed = $0.state { return true } else { return false } }.count
            return "\(provider.name): \(provider.isSignedIn ? "signed in" : "signed out"), \(provider.ownedGames.count) game(s), "
                + "downloads running \(running), paused \(paused), failed \(failed)"
        }
    }
}

// MARK: - Steam

@MainActor
final class SteamStoreProvider: StoreProvider {
    private var model: SteamOwnedGamesModel { .shared }
    let store = GameStore.steam
    let name = "Steam"
    var isSignedIn: Bool { SteamSignIn.isSignedIn }
    var ownedGames: [StoreGameRef] { model.games.map { StoreGameRef(store: .steam, id: String($0.appID), title: $0.name) } }

    func isInstalled(_ id: String, prefix: URL?) -> Bool {
        guard let app = UInt32(id) else { return false }
        if let prefix { return model.isInstalled(appID: app, prefixPath: prefix) }
        return model.installedApps.contains(app)
    }

    var installedIDs: Set<String> { Set(model.installedApps.map { String($0) }) }
    var downloadIDs: Set<String> {
        Set(model.installingApps.union(model.pausedInstalls).union(model.downloadErrors.keys).map { String($0) })
    }

    func downloadStatus(_ id: String) -> StoreDownloadStatus? {
        guard let app = UInt32(id) else { return nil }
        let progress = model.downloadProgress[app]
        let waiting = model.waitingApps.contains(app)
        let state: StoreDownloadState
        if model.pausedInstalls.contains(app) { state = .paused }
        else if model.installingApps.contains(app) { state = (waiting || progress == nil) ? .queued : .active(progress?.fraction ?? 0) }
        else if let error = model.downloadErrors[app] { state = .failed(error) }
        else { return nil }
        let phase: StoreDownloadStatus.Phase
        switch progress?.phase {
        case .checking: phase = .verifying
        case .downloading: phase = .downloading
        case .finishing: phase = .finishing
        default: phase = .preparing
        }
        let eta = progress.flatMap { p in
            phase == .downloading ? DownloadETA.seconds(done: p.doneBytes, total: p.totalBytes, bytesPerSecond: p.bytesPerSecond) : nil
        }
        return StoreDownloadStatus(state: state, doneBytes: progress?.doneBytes ?? 0, totalBytes: progress?.totalBytes ?? 0,
                                   phase: phase,
                                   verifyFraction: progress.map { $0.checkTotal > 0 ? min(1, Double($0.checkDone) / Double($0.checkTotal)) : 0 },
                                   writtenBytes: progress?.installedBytes ?? 0,
                                   etaSeconds: eta, waiting: waiting,
                                   stopping: model.cancellingApps.contains(app), cancellable: model.canCancelInstall(appID: app))
    }

    func install(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)?) -> Bool {
        guard let app = UInt32(id), let prefix else { return false }
        model.startInstall(appID: app, prefixPath: prefix)
        return true
    }

    func pause(_ id: String) { if let app = UInt32(id) { model.pauseInstall(appID: app) } }
    func resume(_ id: String, prefix: URL?) { if let app = UInt32(id) { model.resumeInstall(appID: app) } }
    func cancel(_ id: String) { if let app = UInt32(id) { model.cancelInstall(appID: app) } }

    func uninstall(_ id: String, prefix: URL?) -> Bool {
        guard let app = UInt32(id), let prefix else { return false }
        return model.uninstall(appID: app, prefixPath: prefix)
    }

    func refresh() async { await model.refresh() }

    // MARK: DLC

    var supportsDLC: Bool { true }

    func dlcs(of gameID: String) -> [StoreDLC] {
        guard let app = UInt32(gameID) else { return [] }
        let game = model.games.first { $0.appID == app }
        return (model.availableDLC[app] ?? []).map { id in
            // Its own depots in the game's app info (where Steam lists DLC content), else
            // the DLC app's own download size.
            var bytes = game?.depots.filter { $0.dlcAppID == id }.reduce(UInt64(0)) { $0 + max($1.maxSize, $1.publicSizeBytes) } ?? 0
            if bytes == 0 { bytes = model.dlcMetadata[id]?.downloadSize(for: "windows") ?? 0 }
            return StoreDLC(id: String(id), title: model.dlcMetadata[id]?.name ?? "DLC \(id)", image: nil,
                            sizeBytes: bytes > 0 ? bytes : nil)
        }
    }

    func isDLCInstalled(_ dlcID: String, of gameID: String) -> Bool {
        guard let app = UInt32(gameID), let dlc = UInt32(dlcID) else { return false }
        return model.installedDLC[app]?.contains(dlc) == true
    }

    func dlcDownloadStatus(_ dlcID: String, of gameID: String) -> StoreDownloadStatus? {
        guard let app = UInt32(gameID), let dlc = UInt32(dlcID), model.installingDLC[app] == dlc else { return nil }
        let progress = model.downloadProgress[app]
        return StoreDownloadStatus(state: .active(progress?.fraction ?? 0), doneBytes: progress?.doneBytes ?? 0,
                                   totalBytes: progress?.totalBytes ?? 0, stopping: model.cancellingDLC.contains(dlc),
                                   cancellable: !model.cancellingDLC.contains(dlc))
    }

    func installDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool {
        guard let app = UInt32(gameID), let dlc = UInt32(dlcID), let prefix else { return false }
        model.startDLCInstall(appID: app, dlcAppID: dlc, prefixPath: prefix)
        return true
    }

    func cancelDLC(_ dlcID: String, of gameID: String) {
        guard let app = UInt32(gameID), let dlc = UInt32(dlcID) else { return }
        model.cancelDLCInstall(appID: app, dlcAppID: dlc)
    }

    func uninstallDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool {
        guard let app = UInt32(gameID), let dlc = UInt32(dlcID), let prefix else { return false }
        return model.uninstallDLC(appID: app, dlcAppID: dlc, prefixPath: prefix)
    }

    func loadDLC(of gameID: String, prefix: URL?) async {
        guard let app = UInt32(gameID) else { return }
        await model.loadDLC(appID: app)
        if let prefix { model.refreshInstalledDLC(appID: app, prefixPath: prefix) }
    }

    /// The installed DLC list again, after a DLC install ended.
    func refreshInstalledDLC(of gameID: String, prefix: URL) {
        if let app = UInt32(gameID) { model.refreshInstalledDLC(appID: app, prefixPath: prefix) }
    }

    /// The DLC being installed for a game now, if any (Steam installs one at a time).
    func installingDLC(of gameID: String) -> String? {
        UInt32(gameID).flatMap { model.installingDLC[$0] }.map { String($0) }
    }
}

// MARK: - GOG

@MainActor
final class GOGStoreProvider: StoreProvider {
    private var model: GOGLibraryModel { .shared }
    let store = GameStore.gog
    let name = "GOG"
    var isSignedIn: Bool { model.isSignedIn }
    var ownedGames: [StoreGameRef] { model.games.map { StoreGameRef(store: .gog, id: String($0.id), title: $0.title) } }

    private func game(_ id: String) -> GOGGame? { Int(id).flatMap { number in model.games.first { $0.id == number } } }

    func isInstalled(_ id: String, prefix: URL?) -> Bool { Int(id).map { model.installed[$0] != nil } ?? false }

    var installedIDs: Set<String> { Set(model.installed.keys.map { String($0) }) }
    var downloadIDs: Set<String> {
        Set(Set(model.downloadProgress.keys).union(model.pausedDownloads).union(model.downloadErrors.keys).map { String($0) })
    }

    func downloadStatus(_ id: String) -> StoreDownloadStatus? {
        guard let number = Int(id) else { return nil }
        let bytes = model.downloadedBytes[number]
        let state: StoreDownloadState
        if model.pausedDownloads.contains(number) { state = .paused }
        else if let fraction = model.downloadProgress[number] { state = .active(fraction) }
        else if let error = model.downloadErrors[number] { state = .failed(error) }
        else { return nil }
        return StoreDownloadStatus(state: state, doneBytes: bytes?.done ?? 0, totalBytes: bytes?.total ?? 0,
                                   phase: bytes != nil ? .downloading : .preparing, etaSeconds: model.downloadETASeconds[number],
                                   cancellable: state != .paused)
    }

    func install(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)?) -> Bool {
        guard let game = game(id), let prefix else { return false }
        model.install(game, prefixPath: prefix) { _ in onFinish?() }
        return true
    }

    func pause(_ id: String) { if let game = game(id) { model.pauseDownload(game) } }
    func resume(_ id: String, prefix: URL?) { if let game = game(id) { model.resumeDownload(game) } }
    func cancel(_ id: String) { if let game = game(id) { model.cancelDownload(game) } }

    func uninstall(_ id: String, prefix: URL?) -> Bool {
        guard let number = Int(id), let prefix else { return false }
        return model.uninstall(number, prefixPath: prefix)
    }

    func refresh() async { await model.refresh() }
}

// MARK: - Epic Games

@MainActor
final class EpicStoreProvider: StoreProvider {
    private var model: EpicLibrary { .shared }
    let store = GameStore.epic
    let name = "Epic Games"
    var isSignedIn: Bool { model.signedIn }
    var ownedGames: [StoreGameRef] { model.owned.map { StoreGameRef(store: .epic, id: $0.appName, title: $0.title) } }

    func isInstalled(_ id: String, prefix: URL?) -> Bool { model.installed[id] != nil }

    var installedIDs: Set<String> { Set(model.installed.keys) }
    var downloadIDs: Set<String> { Set(model.downloads.keys) }

    func downloadStatus(_ id: String) -> StoreDownloadStatus? {
        guard let download = model.downloads[id] else { return nil }
        let progress = download.progress
        let state: StoreDownloadState
        switch download.state {
        case .queued: state = .queued
        case .active: state = .active(progress.fraction)
        case .paused: state = .paused
        case .failed(let message): state = .failed(message)
        }
        let phase: StoreDownloadStatus.Phase
        switch progress.phase {
        case .preparing: phase = .preparing
        case .verifying: phase = .verifying
        case .downloading: phase = .downloading
        case .finishing: phase = .finishing
        }
        return StoreDownloadStatus(state: state, doneBytes: progress.doneBytes, totalBytes: progress.totalBytes,
                                   phase: phase,
                                   etaSeconds: phase == .downloading ? DownloadETA.seconds(done: progress.doneBytes, total: progress.totalBytes,
                                                                                           bytesPerSecond: progress.bytesPerSecond) : nil,
                                   waiting: download.state == .queued, cancellable: true)
    }

    func install(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)?) -> Bool {
        model.install(id)
        return true
    }

    func pause(_ id: String) { model.pause(id) }
    func resume(_ id: String, prefix: URL?) { model.install(id) }
    func cancel(_ id: String) { model.cancel(id) }

    func uninstall(_ id: String, prefix: URL?) -> Bool {
        guard model.installed[id] != nil else { return false }
        model.uninstall(id)
        return model.installed[id] == nil
    }

    func refresh() async { await model.refreshLibrary(interactive: false) }

    // MARK: DLC

    var supportsDLC: Bool { true }

    func dlcs(of gameID: String) -> [StoreDLC] {
        (model.dlcs[gameID] ?? []).map { StoreDLC(id: $0.appName, title: $0.title, image: $0.image) }
    }

    func isDLCInstalled(_ dlcID: String, of gameID: String) -> Bool { model.installedDLC[dlcID] != nil }

    /// Epic downloads a DLC as its own app: the same status as a game's.
    func dlcDownloadStatus(_ dlcID: String, of gameID: String) -> StoreDownloadStatus? { downloadStatus(dlcID) }

    func installDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool {
        model.installDLC(dlcID)
        return true
    }

    func cancelDLC(_ dlcID: String, of gameID: String) { model.cancel(dlcID) }

    func uninstallDLC(_ dlcID: String, of gameID: String, prefix: URL?) -> Bool {
        guard model.installedDLC[dlcID] != nil else { return false }
        model.uninstallDLC(dlcID)
        return model.installedDLC[dlcID] == nil
    }

    /// Epic lists a game's DLC with the library, so a refresh brings them.
    func loadDLC(of gameID: String, prefix: URL?) async {}
}

// MARK: - EA app

@MainActor
final class EAStoreProvider: StoreProvider {
    private var model: EALibrary { .shared }
    let store = GameStore.ea
    let name = "EA app"
    var isSignedIn: Bool { model.signedIn }
    var ownedGames: [StoreGameRef] { model.owned.map { StoreGameRef(store: .ea, id: $0.id, title: $0.title) } }

    func isInstalled(_ id: String, prefix: URL?) -> Bool { model.installed[id] != nil }

    var installedIDs: Set<String> { Set(model.installed.keys) }
    var downloadIDs: Set<String> { Set(model.downloads.keys) }

    func downloadStatus(_ id: String) -> StoreDownloadStatus? {
        guard let download = model.downloads[id] else { return nil }
        let progress = download.progress
        let state: StoreDownloadState
        switch download.state {
        case .queued: state = .queued
        case .active: state = .active(progress.fraction)
        case .paused: state = .paused
        case .failed(let message): state = .failed(message)
        }
        let phase: StoreDownloadStatus.Phase
        switch progress.phase {
        case .preparing: phase = .preparing
        case .verifying: phase = .verifying
        case .downloading: phase = .downloading
        case .finishing: phase = .finishing
        }
        return StoreDownloadStatus(state: state, doneBytes: progress.doneBytes, totalBytes: progress.totalBytes,
                                   phase: phase,
                                   etaSeconds: phase == .downloading ? DownloadETA.seconds(done: progress.doneBytes, total: progress.totalBytes,
                                                                                           bytesPerSecond: progress.bytesPerSecond) : nil,
                                   waiting: download.state == .queued, cancellable: true)
    }

    func install(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)?) -> Bool {
        model.install(id)
        return true
    }

    func pause(_ id: String) { model.pause(id) }
    func resume(_ id: String, prefix: URL?) { model.install(id) }
    func cancel(_ id: String) { model.cancel(id) }

    func uninstall(_ id: String, prefix: URL?) -> Bool {
        guard model.installed[id] != nil else { return false }
        model.uninstall(id)
        return model.installed[id] == nil
    }

    func refresh() async { await model.refreshLibrary(interactive: false) }
}

// MARK: - Ubisoft Connect

@MainActor
final class UbisoftStoreProvider: StoreProvider {
    private var model: UbisoftLibrary { .shared }
    let store = GameStore.ubisoft
    let name = "Ubisoft Connect"
    var isSignedIn: Bool { model.signedIn }
    var ownedGames: [StoreGameRef] { model.games.map { StoreGameRef(store: .ubisoft, id: $0.id, title: $0.title) } }

    func isInstalled(_ id: String, prefix: URL?) -> Bool { model.game(id)?.executable != nil }

    var installedIDs: Set<String> { Set(model.games.filter { $0.executable != nil }.map(\.id)) }
    var downloadIDs: Set<String> { Set(model.downloads.keys) }

    func downloadStatus(_ id: String) -> StoreDownloadStatus? {
        guard let download = model.downloads[id] else { return nil }
        let state: StoreDownloadState
        switch download.state {
        case .queued: state = .queued
        case .active: state = .active(download.fraction)
        case .paused: state = .paused
        case .failed(let message): state = .failed(message)
        }
        return StoreDownloadStatus(state: state, doneBytes: download.done, totalBytes: download.total,
                                   phase: download.total > 0 ? .downloading : .preparing,
                                   waiting: download.state == .queued, cancellable: true,
                                   step: download.step.isEmpty ? nil : download.step)
    }

    func install(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)?) -> Bool {
        guard let game = model.game(id), model.canInstall(game) else { return false }
        model.install(game)
        return true
    }

    func pause(_ id: String) { if let game = model.game(id) { model.pause(game) } }
    func resume(_ id: String, prefix: URL?) { if let game = model.game(id) { model.install(game) } }
    func cancel(_ id: String) { if let game = model.game(id) { model.cancel(game) } }

    /// Ubisoft games are removed from the game's page (its folder in Madeira's drive);
    /// the provider has no uninstall of its own yet.
    func uninstall(_ id: String, prefix: URL?) -> Bool { false }

    func refresh() async { model.refresh() }
}
