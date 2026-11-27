// EALibrary: sign-in, the library and game sizes.
// Split from EALibrary.swift (iDeck 3.0 architecture).

import Foundation

extension EALibrary {
    func loadCache(account: String) {
        guard let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == 1, cache.account == Self.accountKey(account) else { return }
        owned = cache.games
        libraryUpdated = cache.updated
    }

    private func writeCache(account: String) {
        let cache = Cache(version: 1, updated: libraryUpdated ?? Date(), account: Self.accountKey(account), games: owned)
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: Self.cacheURL, options: .atomic)
    }

    func loadInstalled() {
        guard let data = try? Data(contentsOf: Self.installedURL),
              let records = try? JSONDecoder().decode([EAInstalledGame].self, from: data) else { return }
        installed = Dictionary(records.map { ($0.offerID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func writeInstalled() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed.values.sorted { $0.offerID < $1.offerID }).write(to: Self.installedURL, options: .atomic)
    }

    /// The machine as the sign-in describes it (the device's own GPU, no AVX).
    private func signInProfile() -> EAHardwareProfile {
        EAHardware.profile(drive: Self.drive, gpuVendor: Self.appleVendor, gpuDevice: 0x0001, avx: false)
    }

    /// EA's login page for this device (a fresh challenge each time).
    func loginURL() -> URL { api.loginURL(profile: signInProfile()) }

    /// The code from EA's login page (EASignInView).
    func signIn(code: String) async throws {
        let session = try await api.signIn(authorizationCode: code)
        signedIn = true
        accountName = session.displayName.isEmpty ? nil : session.displayName
        owned = []; libraryUpdated = nil
        await refreshLibrary(interactive: true)
    }

    /// Removes the tokens and the cached list. Installed games stay, but an EA game needs
    /// the sign-in to start: its licence and the EA app's environment come from the account.
    func signOut() {
        for id in Array(downloads.keys) { pause(id) }
        api.signOut()
        try? FileManager.default.removeItem(at: Self.cacheURL)
        signedIn = false; accountName = nil; owned = []; libraryUpdated = nil
    }

    func handle(_ error: Error, context: String, report: Bool) {
        if case EAAPIError.signedOut = error {
            signedIn = false; accountName = nil
        }
        let reason = (error as? EAAPIError)?.reason ?? (error as? URLError).map { "url-\($0.code.rawValue)" } ?? String(describing: type(of: error))
        EALog.event("[ea-library] \(context) failed reason=\(reason)")
        if report { self.error = error.localizedDescription }
    }

    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var games = try await api.ownedGames()
            let known = Dictionary(owned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Artwork for games not seen before; at most eight lookups at once.
            let wanted = games.indices.filter { known[games[$0].id]?.cover == nil }
            var art: [String: (URL?, URL?)] = [:]
            await withTaskGroup(of: (String, (URL?, URL?)).self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let game = games[wanted[next]]; next += 1
                    group.addTask { [api] in (game.id, await api.images(slug: game.slug)) }
                }
                for _ in 0..<8 { add() }
                while let (id, images) = await group.next() {
                    art[id] = images
                    add()
                }
            }
            for index in games.indices {
                let id = games[index].id
                games[index].cover = art[id]?.0 ?? known[id]?.cover
                games[index].wide = art[id]?.1 ?? known[id]?.wide
            }
            owned = games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            libraryUpdated = Date()
            if let account = api.account() {
                writeCache(account: account.userID)
                if accountName == nil, !account.displayName.isEmpty { accountName = account.displayName }
            }
            EALog.event("[ea-library] owned games=\(owned.count)")
        } catch {
            handle(error, context: "library", report: interactive)
        }
    }

    /// A game's sizes from its live build's archive (the download sheet); once per app run.
    /// The request runs in its own task: the view that asks (a card's .task) is often
    /// redrawn or scrolled away, and its cancellation used to end the request with
    /// CancellationError / URLError -999, which was then stored as "unavailable" for
    /// the rest of the run. A cancelled request now stores nothing, so it is asked again.
    func loadSize(_ id: String) async {
        guard signedIn, sizes[id] == nil else { return }
        if let running = sizeRequests[id] { await running.value; return }
        let request = Task { () -> Void in
            do {
                let build = try await self.api.liveBuild(offerID: id)
                let url = try await self.api.downloadURL(offerID: id, buildID: build.buildID)
                let archive = try await self.downloader.archive(url)
                self.sizes[id] = .known(download: archive.compressedBytes, install: archive.installBytes)
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    self.sizes[id] = .unavailable((error as? EAAPIError)?.errorDescription ?? "EA did not say how large this game is.")
                }
                self.handle(error, context: "size id=\(id)\(cancelled ? " (cancelled, will retry)" : "")", report: false)
            }
        }
        sizeRequests[id] = request
        await request.value
        sizeRequests[id] = nil
    }

    /// Notes the newest build (the Game details page shows Update when it differs).
    func checkForUpdate(_ id: String) async {
        guard signedIn, installed[id] != nil, latestBuild[id] == nil else { return }
        if let build = try? await api.liveBuild(offerID: id) { latestBuild[id] = build.buildID }
    }

    func updateAvailable(_ id: String) -> Bool {
        guard let record = installed[id], let latest = latestBuild[id] else { return false }
        return latest != record.buildID
    }

    /// A first install was paused or failed: its journal is on disk.
    func hasPartialDownload(_ id: String) -> Bool {
        let journal = Self.journalURL(id)
        return FileManager.default.fileExists(atPath: journal.path)
            || FileManager.default.fileExists(atPath: journal.deletingPathExtension().appendingPathExtension("folder").path)
    }
}
