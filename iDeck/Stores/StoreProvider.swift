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
    func downloadState(_ id: String) -> StoreDownloadState?
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
}

extension StoreProvider {
    @discardableResult func install(_ id: String, prefix: URL?) -> Bool { install(id, prefix: prefix, onFinish: nil) }

    /// Install, or resume a paused download: what a page's Install button does.
    func installOrResume(_ id: String, prefix: URL?, onFinish: (@MainActor () -> Void)? = nil) {
        if downloadState(id) == .paused { resume(id, prefix: prefix) } else { install(id, prefix: prefix, onFinish: onFinish) }
    }

    /// Every download of this store that has a state, with its game.
    var downloads: [(game: StoreGameRef, state: StoreDownloadState)] {
        ownedGames.compactMap { game in downloadState(game.id).map { (game, $0) } }
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

    func downloadState(_ id: String) -> StoreDownloadState? {
        guard let app = UInt32(id) else { return nil }
        if model.pausedInstalls.contains(app) { return .paused }
        if let error = model.downloadErrors[app] { return .failed(error) }
        if model.installingApps.contains(app) {
            guard let progress = model.downloadProgress[app] else { return .queued }
            return .active(progress.totalBytes > 0 ? min(1, Double(progress.doneBytes) / Double(progress.totalBytes)) : 0)
        }
        return nil
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

    func downloadState(_ id: String) -> StoreDownloadState? {
        guard let number = Int(id) else { return nil }
        if model.pausedDownloads.contains(number) { return .paused }
        if let error = model.downloadErrors[number] { return .failed(error) }
        if let fraction = model.downloadProgress[number] { return .active(fraction) }
        return nil
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

    func downloadState(_ id: String) -> StoreDownloadState? {
        guard let download = model.downloads[id] else { return nil }
        switch download.state {
        case .queued: return .queued
        case .active: return .active(download.progress.fraction)
        case .paused: return .paused
        case .failed(let message): return .failed(message)
        }
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

// MARK: - EA app

@MainActor
final class EAStoreProvider: StoreProvider {
    private var model: EALibrary { .shared }
    let store = GameStore.ea
    let name = "EA app"
    var isSignedIn: Bool { model.signedIn }
    var ownedGames: [StoreGameRef] { model.owned.map { StoreGameRef(store: .ea, id: $0.id, title: $0.title) } }

    func isInstalled(_ id: String, prefix: URL?) -> Bool { model.installed[id] != nil }

    func downloadState(_ id: String) -> StoreDownloadState? {
        guard let download = model.downloads[id] else { return nil }
        switch download.state {
        case .queued: return .queued
        case .active: return .active(download.progress.fraction)
        case .paused: return .paused
        case .failed(let message): return .failed(message)
        }
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

    func downloadState(_ id: String) -> StoreDownloadState? {
        guard let download = model.downloads[id] else { return nil }
        switch download.state {
        case .queued: return .queued
        case .active: return .active(download.fraction)
        case .paused: return .paused
        case .failed(let message): return .failed(message)
        }
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
