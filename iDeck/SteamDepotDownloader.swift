// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Substantially
// rewritten by 125hz for the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation
import zlib
import CommonCrypto

/// Progress for one application install, across all of its depots.
struct SteamDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, checking, downloading, finishing }
    var phase: Phase = .preparing
    /// Compressed bytes to fetch for the whole install (all selected depots).
    var totalBytes: UInt64 = 0
    /// Compressed bytes already on disk, including chunks resumed from a
    /// previous attempt.
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0
    var checkTotal: UInt64 = 0
    var checkDone: UInt64 = 0
    var reusedBytes: UInt64 = 0

    var checkFraction: Double {
        checkTotal > 0 ? min(1, Double(checkDone) / Double(checkTotal)) : 0
    }

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

/// Orchestrates downloading an owned application's Windows depots from the
/// Steam content network into a Steam library folder.
///
/// Follows Steam's content protocol: the account's depot key and the
/// manifest request code come from the CM connection, which issues them only
/// to an account that owns the depot; manifests and chunks come from content
/// servers over HTTPS. Nothing here alters the downloaded files.
///
/// Behaviour:
/// - All manifests are fetched first, so progress covers the whole install.
/// - Completed chunks are journaled per depot manifest; a cancelled, failed or
///   interrupted install resumes without re-fetching them.
/// - Files are sized to their manifest length, so an update that shrinks a
///   file cannot leave stale trailing bytes.
/// - Chunk writes happen on the download tasks with pwrite, never on the
///   main actor; a dedicated URLSession keeps chunks out of the URL cache.
/// - Manifest paths are validated to stay inside the install folder, and
///   directory names are folded case-insensitively (Windows semantics on a
///   case-sensitive iOS volume).
/// - Each chunk retries on other content servers before the install fails.
@MainActor
final class DepotDownloader {
    private let session: SteamCMSession
    private var depotKeys: [UInt32: Data] = [:]
    private var cdnAuthTokens: [String: String] = [:]  // "depot|host" -> "?auth=…" fragment
    private var maxConcurrentChunks: Int {
        let process = ProcessInfo.processInfo
        // Allow extra requests while other chunks decrypt or write, but
        // re-check thermal and Low Power Mode changes during the transfer.
        if process.isLowPowerModeEnabled { return 2 }
        switch process.thermalState {
        case .nominal: return min(24, max(16, process.activeProcessorCount * 3))
        case .fair: return min(12, max(6, process.activeProcessorCount * 2))
        case .serious: return 4
        case .critical: return 1
        @unknown default: return 4
        }
    }
    private let attemptsPerChunk = 5
    private let hostPoolSize = 12


    private nonisolated static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // No bandwidth throttle is applied. This is a connection safety limit.
        config.httpMaximumConnectionsPerHost = 24
        return URLSession(configuration: config)
    }()

    /// Replaces the content server directory (host tests only): the servers
    /// to fetch from, as `https://host` or `http://host:port` URLs.
    var contentHosts: ((_ appID: UInt32) async throws -> [String])?

    init(session: SteamCMSession) {
        self.session = session
    }

    // MARK: - Public API

    /// Download an app into `steamApps/common/<installdir>` and write its
    /// appmanifest. Returns the install folder. Throws CancellationError when
    /// the calling task is cancelled; completed chunks stay journaled.
    func install(_ app: SteamAppInfo, steamApps: URL,
                 ownedDepots: @escaping () async -> Set<UInt32>? = { nil },
                 includedDLC: Set<UInt32> = [],
                 dlcOnly: Bool = false,
                 progress report: @escaping (SteamDownloadProgress) -> Void) async throws -> URL {
        let selected = app.installDepots(includingDLC: includedDLC)
        let depots = dlcOnly
            ? selected.filter { $0.dlcAppID.map { includedDLC.contains($0) } == true }
            : selected
        guard !depots.isEmpty else { throw SteamError.depotNotFound(app.appID) }
        // Before the key requests, so a refused depot still has its selection logged.
        SteamLog.event("[steam-depot] selection app=\(app.appID) build=\(app.buildID) \(app.depotSelectionSummary())")

        let folderName = SteamInstallFiles.safeFolderName(app.installDir.isEmpty ? "app_\(app.appID)" : app.installDir)
        let installURL = steamApps.appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        let journalDir = steamApps.appendingPathComponent("downloading", isDirectory: true)
            .appendingPathComponent("\(app.appID)", isDirectory: true)
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        var state = SteamDownloadProgress()
        report(state)

        depotCache = steamApps.appendingPathComponent("depotcache", isDirectory: true)
        let hosts: [String]
        if let provider = contentHosts { hosts = try await provider(app.appID) } else { hosts = try await contentServers(appID: app.appID) }
        guard !hosts.isEmpty else { throw SteamError.chunkDownloadFailed("No content servers are available.") }

        // 1. Keys, manifests and per-host authorization for every depot.
        let health = ContentHostHealth()
        let pool = Array(hosts.prefix(hostPoolSize))
        var plans: [DepotPlan] = []
        var licenseSkipped: [UInt32] = []
        // The logged-on account, for the install record. Read while the session
        // is connected: it idles out during a long download.
        var accountID: UInt64 = 0
        for depot in depots {
            try Task.checkCancellation()
            guard let gid = depot.publicManifestID else { continue }
            let key: Data
            do {
                key = try await depotKey(depotID: depot.depotID, appID: app.appID)
            } catch SteamError.depotKeyNotFound(let refused) {
                // A depot Steam refuses AND the account's licenses do not
                // include is content this account does not own (another
                // edition, extra content): it is left out. Any other refusal
                // still fails.
                if let owned = await ownedDepots(), !owned.isEmpty, !owned.contains(refused) {
                    licenseSkipped.append(refused)
                    continue
                }
                throw SteamError.depotKeyNotFound(refused)
            }
            if session.steamID != 0 { accountID = session.steamID }
            let contentAppID = !app.freeToDownload ? (depot.fromApp ?? app.appID) : app.appID
            let manifest = try await fetchManifest(depotID: depot.depotID, appID: contentAppID,
                                                   manifestGID: gid, key: key, hosts: hosts)
            var auth: [String: String] = [:]
            await withTaskGroup(of: (String, String).self) { group in
                for host in pool {
                    group.addTask {
                        (host, await self.cdnAuthFragment(depotID: depot.depotID,
                                                          appID: contentAppID, host: host))
                    }
                }
                for await (host, fragment) in group {
                    auth[host] = fragment
                }
            }
            plans.append(DepotPlan(depotID: depot.depotID, manifestGID: gid, key: key, manifest: manifest,
                                   hosts: pool, auth: auth,
                                   declaredSize: depot.publicSizeBytes, health: health))
        }
        if !licenseSkipped.isEmpty {
            SteamLog.event("[steam-depot] license app=\(app.appID) skipped=\(licenseSkipped.map(String.init).joined(separator: ",")) kept=\(plans.map { String($0.depotID) }.joined(separator: ","))")
        }
        guard !plans.isEmpty else {
            if let refused = licenseSkipped.first { throw SteamError.depotKeyNotFound(refused) }
            throw SteamError.depotNotFound(app.appID)
        }

        // 2. Prepare files and load journals off the main actor.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(plans: plans, installURL: installURL, journalDir: journalDir)
        }.value
        state.totalBytes = prepared.totalBytes
        state.doneBytes = prepared.doneBytes
        state.phase = .downloading
        report(state)
        SteamLog.event("[steam-depot] install begin app=\(app.appID) depots=\(plans.count) files=\(prepared.fileCount) resume=\(prepared.doneBytes > 0 ? 1 : 0)")

        let remaining = prepared.remainingUncompressed
        if remaining > 0 {
            let values = try? installURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? Int64.max))
            if available < remaining { throw SteamError.insufficientDiskSpace(needed: remaining, available: available) }
        }

        // 3a. Read existing game files sequentially in large blocks before
        // requesting the network. This avoids opening and hashing the same
        // file separately for every chunk, especially on updates and resumes.
        // Only verified SHA-1 matches may skip an HTTP request.
        var pending = prepared.pending
        try await checkExisting(plans: plans, prepared: prepared,
                                pending: &pending, state: &state, report: report)

        // 3b. Transfer changed/absent chunks across independent depots.
        // Keep depots that write the same output path in ordered batches,
        // preserving Steam's final overlay while using idle CDN connections.
        let started = Date()
        let resumedBytes = state.doneBytes
        var actualWrittenBytes: UInt64 = 0
        var lastReport = Date.distantPast
        let batches = SteamChunkScheduler.batches(paths: prepared.paths)
        let journals = try prepared.journals.map { try JournalWriter(url: $0) }
        let attempts = attemptsPerChunk
        defer { journals.forEach { $0.close() } }
        SteamLog.event("[steam-depot] transfer batches=\(batches.count) initial-parallelism=\(maxConcurrentChunks)")
        for batch in batches {
            try Task.checkCancellation()
            var scheduler = SteamChunkScheduler(counts: batch.map { pending[$0].count })
            guard scheduler.remaining > 0 else { continue }
            try await withThrowingTaskGroup(of: (Int, UInt64, UInt64, UInt64).self) { group in
                var inFlight = 0
                func enqueue() -> Bool {
                    guard let next = scheduler.next() else { return false }
                    let depotIndex = batch[next.depot]
                    let plan = plans[depotIndex]
                    let item = pending[depotIndex][next.item]
                    let chunk = plan.manifest.files[item.file].chunks[item.chunk]
                    let path = prepared.paths[depotIndex][item.file]
                    inFlight += 1
                    group.addTask {
                        let written = try await Self.fetchChunk(
                            chunk, plan: plan, path: path, attempts: attempts,
                            seed: item.file &+ item.chunk)
                        return (depotIndex, item.key, UInt64(chunk.compressedSize), written)
                    }
                    return true
                }

                // Finished tasks release slots. Changes in Low Power Mode or
                // thermal state are applied before scheduling new chunks.
                let initialCapacity = maxConcurrentChunks
                while inFlight < initialCapacity && enqueue() {}
                for try await (depotIndex, key, bytes, written) in group {
                    inFlight -= 1
                    journals[depotIndex].append(key)
                    state.doneBytes += bytes
                    actualWrittenBytes &+= written
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        let elapsed = now.timeIntervalSince(started)
                        if elapsed > 1 {
                            state.bytesPerSecond = Double(state.doneBytes - resumedBytes) / elapsed
                        }
                        report(state)
                    }
                    let capacity = maxConcurrentChunks
                    while inFlight < capacity && enqueue() {}
                }
            }
        }

        // 4. Install record. Sizes come from the manifests; no tree walk.
        state.phase = .finishing
        report(state)
        let installed = plans.map { plan in
            AppManifestWriter.InstalledDepot(depotID: Int(plan.depotID), manifestGID: plan.manifestGID,
                                             size: Int64(plan.manifest.totalUncompressedSize))
        }
        // Depots taken from another app are that app's content. Valve's client
        // refuses a launch until the owner app has its own record, so both
        // records are written the way the client writes them.
        var owners: [UInt32: UInt32] = [:]
        for depot in depots { if let from = depot.fromApp, from != app.appID { owners[depot.depotID] = from } }
        let own = installed.filter { owners[UInt32($0.depotID)] == nil }
        let shared = installed.filter { owners[UInt32($0.depotID)] != nil }
        // Files Valve's client must customize per user before they run, as
        // Windows-style install-relative paths for the record's CheckGuid block.
        let custom = plans.flatMap { plan in
            plan.manifest.files.filter { $0.flags & DepotManifest.customExecutableFlag != 0 && !$0.isDirectory }
                .map { $0.filename.replacingOccurrences(of: "/", with: "\\") }
        }
        if !custom.isEmpty { SteamLog.event("[steam-record] custom-executables app=\(app.appID) custom=\(custom.count)") }
        if !dlcOnly {
            try AppManifestWriter.writeManifest(
                appID: app.appID, name: app.name, installDir: folderName, buildID: app.buildID,
                steamID: accountID, sizeOnDisk: prepared.totalUncompressed,
                steamAppsPath: steamApps.path, installedDepots: own,
                sharedDepots: shared.map { ($0.depotID, Int(owners[UInt32($0.depotID)]!)) },
                customExecutables: custom)
        }
        if !shared.isEmpty && !dlcOnly {
            var written = 0, skipped = 0
            for ownerID in Set(owners.values).sorted() {
                let depots = shared.filter { owners[UInt32($0.depotID)] == ownerID }
                guard !depots.isEmpty else { continue }
                // The owner keeps its own installdir, as in the record Valve's
                // client writes for it ("Shared Only"); the files stay in this
                // app's folder. Skipping owners with another folder left GTA V
                // Enhanced's owner 1899670 (installdir RGLSC) without the depot,
                // and every launch failed with "required app 1899670 not ready".
                guard let owner = app.sharedOwners[ownerID] else {
                    skipped += 1; continue
                }
                let ownerFolder = SteamInstallFiles.safeFolderName(owner.installDir)
                try AppManifestWriter.mergeOwnerManifest(ownerAppID: ownerID, ownerName: owner.name, ownerBuildID: owner.buildID,
                                                         installDir: ownerFolder.isEmpty ? folderName : ownerFolder,
                                                         steamID: accountID, steamAppsPath: steamApps.path,
                                                         depots: depots)
                written += 1
            }
            SteamLog.event("[steam-shared-record] app=\(app.appID) shared=\(shared.count) owners-written=\(written) owners-skipped=\(skipped)")
        }
        if dlcOnly {
            let common = steamApps.appendingPathComponent("common", isDirectory: true)
                .standardizedFileURL.path
            var newlyInstalledFiles: [String] = []
            for (index, _) in plans.enumerated() {
                for fileIndex in prepared.paths[index].indices {
                    let path = prepared.paths[index][fileIndex]
                    guard !path.isEmpty,
                          !prepared.existing[index][fileIndex],
                          path.hasPrefix(common + "/") else { continue }
                    newlyInstalledFiles.append(String(path.dropFirst(common.count + 1)))
                }
            }
            for dlcID in includedDLC {
                try SteamDLCRecords.markInstalled(parentID: app.appID, dlcID: dlcID,
                                                  files: newlyInstalledFiles, steamApps: steamApps)
            }
        }
        try? FileManager.default.removeItem(at: journalDir)
        SteamLog.event("[steam-depot] install complete app=\(app.appID) bytes=\(prepared.totalUncompressed) physical-write-requests=\(actualWrittenBytes) seconds=\(Int(Date().timeIntervalSince(started)))")
        return installURL
    }

    /// Whether a previous attempt left resumable progress for this app.
    static func hasPartialDownload(appID: UInt32, steamApps: URL) -> Bool {
        let dir = steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".journal") }
    }

    // MARK: - Plan

    struct DepotPlan: Sendable {
        let depotID: UInt32
        let manifestGID: UInt64
        let key: Data
        let manifest: DepotManifest
        let hosts: [String]
        let auth: [String: String]
        let declaredSize: UInt64
        let health: ContentHostHealth
    }

    struct WorkItem: Sendable {
        let file: Int
        let chunk: Int
        var key: UInt64 { UInt64(file) << 32 | UInt64(chunk) }
    }

    struct Prepared: Sendable {
        var paths: [[String]] = []       // per depot, per file: absolute path ("" = skipped)
        var existing: [[Bool]] = []      // per depot, per file: had content before this install
        var pending: [[WorkItem]] = []   // per depot: chunks still to fetch
        var journals: [URL] = []
        var totalBytes: UInt64 = 0
        var doneBytes: UInt64 = 0
        var totalUncompressed: UInt64 = 0
        var remainingUncompressed: UInt64 = 0
        var fileCount = 0
    }

    private nonisolated static func prepare(plans: [DepotPlan], installURL: URL, journalDir: URL) throws -> Prepared {
        let fm = FileManager.default
        var result = Prepared()
        var folded: [String: String] = [:]   // lowercased relative dir -> first spelling
        var createdDirectories = Set<String>() // one mkdir traversal per distinct output directory
        let journalNames = Set(plans.map { "depot_\($0.depotID)_\($0.manifestGID).journal" })
        // A journal for an older manifest describes different file contents.
        for name in (try? fm.contentsOfDirectory(atPath: journalDir.path)) ?? [] where !journalNames.contains(name) {
            try? fm.removeItem(at: journalDir.appendingPathComponent(name))
        }
        for plan in plans {
            try Task.checkCancellation()
            let journalURL = journalDir.appendingPathComponent("depot_\(plan.depotID)_\(plan.manifestGID).journal")
            let done = JournalWriter.load(journalURL)
            var paths: [String] = []
            var existing: [Bool] = []
            var pending: [WorkItem] = []
            paths.reserveCapacity(plan.manifest.files.count)
            for (fileIndex, file) in plan.manifest.files.enumerated() {
                // Symlinks (flag 0x200) have no Windows meaning here; skip them.
                guard file.flags & 0x200 == 0,
                      let relative = SteamInstallFiles.safeRelativePath(file.filename, folded: &folded) else {
                    if file.flags & 0x200 == 0 { SteamLog.trace("rejected manifest path in depot \(plan.depotID)") }
                    paths.append(""); existing.append(false); continue
                }
                let url = installURL.appendingPathComponent(relative)
                if file.isDirectory {
                    if createdDirectories.insert(url.path).inserted {
                        try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    }
                    paths.append(""); existing.append(false); continue
                }
                let parent = url.deletingLastPathComponent()
                if createdDirectories.insert(parent.path).inserted {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                var before = stat()
                let hadContent = stat(url.path, &before) == 0 && before.st_size > 0
                existing.append(hadContent)
                try sizeFile(url.path, to: file.size)
                paths.append(url.path)
                result.fileCount += 1
                result.totalUncompressed += file.size
                var pendingBytes: UInt64 = 0
                for (chunkIndex, chunk) in file.chunks.enumerated() {
                    let item = WorkItem(file: fileIndex, chunk: chunkIndex)
                    result.totalBytes += UInt64(chunk.compressedSize)
                    // Journal records are only valid if the corresponding file
                    // was still present and large enough before ftruncate.
                    // Otherwise an interrupted uninstall/reinstall could skip
                    // missing content and leave an apparently complete game.
                    let priorSize = hadContent ? UInt64(before.st_size) : 0
                    if done.contains(item.key),
                       chunk.offset <= priorSize,
                       UInt64(chunk.uncompressedSize) <= priorSize - chunk.offset {
                        result.doneBytes += UInt64(chunk.compressedSize)
                    } else {
                        pending.append(item)
                        pendingBytes += UInt64(chunk.uncompressedSize)
                    }
                }
                // Space already allocated to an existing file is reused; only
                // its growth needs new space (sparse new files need all of it).
                let beforeSize = hadContent ? UInt64(before.st_size) : 0
                result.remainingUncompressed += hadContent
                    ? (file.size > beforeSize ? file.size - beforeSize : 0) : pendingBytes
            }
            result.paths.append(paths)
            result.existing.append(existing)
            result.pending.append(pending)
            result.journals.append(journalURL)
        }
        return result
    }

    /// Create or resize a file to its manifest length. Existing bytes below
    /// that length are kept so resumed and updated installs reuse them.
    private nonisolated static func sizeFile(_ path: String, to size: UInt64) throws {
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw SteamError.chunkDownloadFailed("Cannot create a game file (errno \(errno)).") }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, UInt64(info.st_size) == size { return }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw SteamError.chunkDownloadFailed("Cannot size a game file (errno \(errno)).")
        }
    }

    // MARK: - Chunks

    /// Verify only files that already had bytes, grouped by file and ordered
    /// by offset. An unchanged chunk is written to the persistent journal; if
    /// cancellation happens next, it remains safe to resume.
    private func checkExisting(plans: [DepotPlan], prepared: Prepared,
                               pending: inout [[WorkItem]],
                               state: inout SteamDownloadProgress,
                               report: (SteamDownloadProgress) -> Void) async throws {
        struct Check: Sendable {
            let depotIndex: Int
            let path: String
            let items: [WorkItem]
            let entries: [SteamExistingChunkVerifier.Entry]
        }
        var checks: [Check] = []
        for (depotIndex, plan) in plans.enumerated() {
            var files: [Int: [WorkItem]] = [:]
            for item in pending[depotIndex] where prepared.existing[depotIndex][item.file] {
                files[item.file, default: []].append(item)
            }
            for (fileIndex, items) in files {
                let chunks = plan.manifest.files[fileIndex].chunks
                let ordered = items.sorted { chunks[$0.chunk].offset < chunks[$1.chunk].offset }
                let entries = ordered.map { item in
                    let chunk = chunks[item.chunk]
                    return SteamExistingChunkVerifier.Entry(
                        offset: chunk.offset, length: Int(chunk.uncompressedSize), sha: chunk.sha)
                }
                checks.append(Check(depotIndex: depotIndex,
                                    path: prepared.paths[depotIndex][fileIndex],
                                    items: ordered, entries: entries))
            }
        }
        guard !checks.isEmpty else { return }
        state.phase = .checking
        state.checkTotal = checks.reduce(0) { count, check in
            count + check.entries.reduce(0) { $0 + UInt64($1.length) }
        }
        state.checkDone = 0
        report(state)
        let isExternal = checks.contains { $0.path.contains("/LiveFiles/") || $0.path.contains("/External/") }
        let readers = isExternal ? 3 : min(8, max(5, ProcessInfo.processInfo.activeProcessorCount))
        let journals = try plans.indices.map { try JournalWriter(url: prepared.journals[$0]) }
        defer { journals.forEach { $0.close() } }
        var verified: [Set<UInt64>] = plans.map { _ in [] }
        var lastReport = Date.distantPast
        try await withThrowingTaskGroup(of: (Check, [Bool]).self) { group in
            var next = 0
            func enqueue() {
                guard next < checks.count else { return }
                let check = checks[next]
                next += 1
                group.addTask { (check, try SteamExistingChunkVerifier.verify(
                    path: check.path, entries: check.entries)) }
            }
            for _ in 0..<min(readers, checks.count) { enqueue() }
            for try await (check, results) in group {
                try Task.checkCancellation()
                for (index, matches) in results.enumerated() {
                    let item = check.items[index]
                    let chunk = plans[check.depotIndex].manifest.files[item.file].chunks[item.chunk]
                    state.checkDone += UInt64(chunk.uncompressedSize)
                    if matches {
                        let key = item.key
                        verified[check.depotIndex].insert(key)
                        journals[check.depotIndex].append(key)
                        let count = UInt64(chunk.compressedSize)
                        state.doneBytes += count
                        state.reusedBytes += count
                    }
                }
                let now = Date()
                if now.timeIntervalSince(lastReport) >= 0.25 {
                    lastReport = now
                    report(state)
                }
                enqueue()
            }
        }
        for index in pending.indices {
            pending[index].removeAll { verified[index].contains($0.key) }
        }
        state.checkDone = state.checkTotal
        state.phase = .downloading
        report(state)
        SteamLog.event("[steam-depot] verified existing chunks=" +
                       String(verified.reduce(0) { $0 + $1.count }) +
                       " reused-bytes=" + String(state.reusedBytes))
    }

    private nonisolated static func fetchChunk(_ chunk: DepotManifest.ChunkEntry, plan: DepotPlan,
                                               path: String, attempts: Int, seed: Int) async throws -> UInt64 {
        var lastError: Error = SteamError.chunkDownloadFailed("No content server responded.")
        var attemptedHosts = Set<String>()
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            if attemptedHosts.count == plan.hosts.count { attemptedHosts.removeAll() }
            let order = plan.health.order(plan.hosts, seed: seed)
            let host = order.first { !attemptedHosts.contains($0) } ?? order[0]
            attemptedHosts.insert(host)
            let url = "\(host)/depot/\(plan.depotID)/chunk/\(chunk.shaHex)\(plan.auth[host] ?? "")"
            do {
                let timing = SteamCDNRequestMetrics()
                let started = ProcessInfo.processInfo.systemUptime
                let encrypted = try await download(url, metrics: timing)
                let transferSeconds = max(0.001, ProcessInfo.processInfo.systemUptime - started)
                let data = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: plan.key,
                                                             expectedCRC: chunk.crc,
                                                             expectedSize: Int(chunk.uncompressedSize))
                guard data.count == Int(chunk.uncompressedSize) else { throw SteamError.checksumMismatch }
                // Existing chunks were SHA-1 verified: remaining work must
                // be rewritten, not reread before pwrite.
                let written = try write(data, to: path, offset: chunk.offset)
                plan.health.recordSuccess(host, bytes: encrypted.count,
                                          seconds: transferSeconds,
                                          responseLatency: timing.firstByteSeconds)
                return written
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                let reason = failureReason(error)
                if plan.health.recordFailure(host) {
                    let server = host.replacingOccurrences(of: "https://", with: "")
                    DispatchQueue.main.async {
                        SteamLog.event("[steam-cdn] host demoted host=\(server) reason=\(reason)")
                    }
                }
                SteamLog.trace("chunk attempt \(attempt + 1) failed: \(reason)")
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 400_000_000) }
            }
        }
        throw lastError
    }

    private nonisolated static func failureReason(_ error: Error) -> String {
        if let url = error as? URLError { return "url\(url.code.rawValue)" }
        if case SteamError.chunkDecodeFailed(let format) = error { return "decode-\(format)" }
        if case SteamError.checksumMismatch = error { return "checksum" }
        return "other"
    }

    private nonisolated static func write(_ data: Data, to path: String,
                                           offset: UInt64) throws -> UInt64 {
        var written: UInt64 = 0
        let errorCode = path.withCString { pathPointer in
            data.withUnsafeBytes { raw in
                ideck_steam_write_chunk(
                    pathPointer, raw.baseAddress, raw.count, offset,
                    0, &written
                )
            }
        }
        guard errorCode == 0 else {
            throw SteamError.chunkDownloadFailed("Cannot write a game file (errno \(errorCode)).")
        }
        return written
    }

    private nonisolated static func download(_ urlString: String,
                                             metrics: SteamCDNRequestMetrics? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SteamError.chunkDownloadFailed("Invalid content URL.") }
        let data: Data
        let response: URLResponse
        if let metrics {
            (data, response) = try await http.data(for: URLRequest(url: url), delegate: metrics)
        } else {
            (data, response) = try await http.data(from: url)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw SteamError.chunkDownloadFailed("Content server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    // MARK: - Manifest

    private func fetchManifest(depotID: UInt32, appID: UInt32, manifestGID: UInt64,
                               key: Data, hosts: [String]) async throws -> DepotManifest {
        let requestCode = try await manifestRequestCode(depotID: depotID, appID: appID, manifestGID: manifestGID)
        var lastError: Error = SteamError.manifestFetchFailed("No content server returned the manifest.")
        for host in hosts.prefix(6) {
            try Task.checkCancellation()
            let auth = await cdnAuthFragment(depotID: depotID, appID: appID, host: host)
            let code = requestCode == 0 ? "" : "/\(requestCode)"
            do {
                let raw = try await Self.download("\(host)/depot/\(depotID)/manifest/\(manifestGID)/5\(code)\(auth)")
                let cache = depotCache
                return try await Task.detached(priority: .userInitiated) {
                    let (manifest, payload) = try Self.parseManifestKeepingPayload(raw, depotID: depotID, manifestGID: manifestGID, key: key)
                    // Valve's client reads a depot's manifest from steamapps/depotcache
                    // when it prepares a per-user custom executable. Keep it for such depots.
                    if let cache, manifest.files.contains(where: { $0.flags & DepotManifest.customExecutableFlag != 0 }) {
                        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                        let file = cache.appendingPathComponent("\(depotID)_\(manifestGID).manifest")
                        let existing = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                        if existing != payload.count { try? payload.write(to: file, options: .atomic) }
                    }
                    return manifest
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                SteamLog.trace("manifest from a content server failed: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private nonisolated static func parseManifest(_ raw: Data, depotID: UInt32, manifestGID: UInt64, key: Data) throws -> DepotManifest {
        try parseManifestKeepingPayload(raw, depotID: depotID, manifestGID: manifestGID, key: key).0
    }

    /// The manifest and the binary manifest bytes it was parsed from (unzipped, decrypted).
    private nonisolated static func parseManifestKeepingPayload(_ raw: Data, depotID: UInt32, manifestGID: UInt64,
                                                                key: Data) throws -> (DepotManifest, Data) {
        // Content servers deliver the manifest as a single-entry ZIP.
        let payload = raw.starts(with: [0x50, 0x4B]) ? try unzipSingleFile(raw) : raw
        if let plain = try? DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: payload, depotKey: key),
           !plain.files.isEmpty {
            return (plain, payload)
        }
        // Older depots encrypt the whole manifest with the depot key.
        let decrypted = try ContentDecryptor.decryptChunk(encryptedData: payload, depotKey: key)
        let inflated = (try? ContentDecryptor.decompressChunk(compressedData: decrypted, expectedSize: 0)) ?? decrypted
        return (try DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: inflated, depotKey: key), inflated)
    }

    /// steamapps/depotcache while an install runs.
    private var depotCache: URL?

    /// Extract the single deflated entry from a manifest ZIP. No zip lib needed —
    /// parse the local file header and inflate the raw deflate stream.
    nonisolated static func unzipSingleFile(_ data: Data) throws -> Data {
        let data = Data(data)  // zero-based indices
        guard data.count > 30,
              data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 else {
            throw SteamError.manifestFetchFailed("Not a zip")
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1]) << 8 | Int(data[o+2]) << 16 | Int(data[o+3]) << 24 }
        let method = u16(8)
        let compSize = u32(18)
        let uncompSize = u32(22)
        let nameLen = u16(26), extraLen = u16(28)
        let start = 30 + nameLen + extraLen
        guard start + compSize <= data.count, method == 0 || method == 8,
              uncompSize <= ContentDecryptor.maximumChunkBytes * 4 else {
            throw SteamError.manifestFetchFailed("Bad zip entry (method \(method))")
        }
        let entry = data.subdata(in: start..<(start + compSize))
        if method == 0 { return entry }

        // Zip stores raw deflate — inflate with zlib, negative windowBits
        var strm = z_stream()
        let cap = max(uncompSize, 1024)
        var out = Data(count: cap)
        var n = -1
        entry.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                strm.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                strm.avail_in = UInt32(entry.count)
                strm.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                strm.avail_out = UInt32(cap)
                guard inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                let r = inflate(&strm, Z_FINISH)
                inflateEnd(&strm)
                if r == Z_STREAM_END { n = Int(strm.total_out) }
            }
        }
        guard n >= 0 else { throw SteamError.decompressionFailed }
        out.count = n
        return out
    }

    // MARK: - Depot Key

    private func depotKey(depotID: UInt32, appID: UInt32) async throws -> Data {
        if let cached = depotKeys[depotID] { return cached }
        try await session.ensureConnected()

        var request = CMsgClientGetDepotDecryptionKey()
        request.depotID = depotID
        request.appID = appID

        let response = try await session.sendAndWait(
            eMsg: .clientGetDepotDecryptionKey,
            body: request.serialize(),
            responseEMsg: .clientGetDepotDecryptionKeyResponse,
            timeout: 15
        )

        let keyResponse = try CMsgClientGetDepotDecryptionKeyResponse.deserialize(from: response.body)
        // Steam only issues keys for depots this account owns.
        guard EResult(rawValue: UInt32(keyResponse.eresult))?.isSuccess == true,
              keyResponse.depotEncryptionKey.count == 32 else {
            SteamLog.event("[steam-depot] depot-key refused app=\(appID) depot=\(depotID) eresult=\(keyResponse.eresult)")
            throw SteamError.depotKeyNotFound(depotID)
        }

        depotKeys[depotID] = keyResponse.depotEncryptionKey
        return keyResponse.depotEncryptionKey
    }

    // MARK: - Manifest Request Code

    private func manifestRequestCode(depotID: UInt32, appID: UInt32, manifestGID: UInt64) async throws -> UInt64 {
        try await session.ensureConnected()
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: appID)
        encoder.writeUInt32(fieldNumber: 2, value: depotID)
        encoder.writeUInt64(fieldNumber: 3, value: manifestGID)

        let responseData = try await session.callServiceMethod(
            method: .getManifestRequestCode,
            body: encoder.data,
            timeout: 15
        )

        var decoder = ProtobufDecoder(responseData)
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 1 {
                // manifest_request_code is fixed64 on the wire
                return tag.wireType == .fixed64 ? try decoder.readFixed64() : try decoder.readVarint()
            }
            try decoder.skip(wireType: tag.wireType)
        }

        return 0 // No request code needed (older depots)
    }

    // MARK: - CDN Discovery + Auth

    /// Content server discovery via the public Web API
    /// (IContentServerDirectoryService/GetServersForSteamPipe). No account
    /// token is attached; the directory does not require one.
    enum ServerEligibility: Equatable { case usable, noHTTPS, other }

    /// Directory fields as served by GetServersForSteamPipe: https_support
    /// ("mandatory", "optional", "unavailable"), use_as_proxy, and an optional
    /// allowed_app_ids restriction.
    nonisolated static func serverEligibility(_ server: [String: Any], appID: UInt32) -> ServerEligibility {
        if let https = (server["https_support"] as? String)?.lowercased(), https != "mandatory", https != "optional" {
            return .noHTTPS
        }
        if (server["use_as_proxy"] as? Bool) == true || (server["use_as_proxy"] as? NSNumber)?.boolValue == true {
            return .other
        }
        if let allowed = server["allowed_app_ids"] as? [Any], !allowed.isEmpty,
           !allowed.contains(where: { ($0 as? NSNumber)?.uint32Value == appID || ($0 as? String) == String(appID) }) {
            return .other
        }
        return .usable
    }

    private func contentServers(appID: UInt32) async throws -> [String] {
        // Ask Valve again for every install, including after Wi-Fi, cellular,
        // public IP or VPN changes. The Web API uses the request's source IP
        // to geolocate when cell_id is omitted. A saved Steam cell can refer
        // to a different network and route downloads through the wrong region.
        var hosts: [String] = []
        do {
            guard let url = URL(string: "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?max_servers=32") else {
                throw SteamError.chunkDownloadFailed("Bad content directory URL")
            }
            let (data, response) = try await Self.http.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SteamError.chunkDownloadFailed("Content directory HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp = json["response"] as? [String: Any],
                  let servers = resp["servers"] as? [[String: Any]] else {
                throw SteamError.chunkDownloadFailed("Content directory returned unexpected data")
            }
            // In the directory's order. The directory marks some CDN servers
            // https_support "unavailable"; requesting them over HTTPS fails the
            // TLS handshake (NSURLError -1200). Such servers, proxy-only entries
            // and servers restricted to other apps are skipped.
            var skippedHTTP = 0, skippedOther = 0
            for server in servers {
                let host = (server["vhost"] as? String) ?? (server["host"] as? String) ?? ""
                guard Self.usableContentHost(host) else { skippedOther += 1; continue }
                switch Self.serverEligibility(server, appID: appID) {
                case .usable: break
                case .noHTTPS: skippedHTTP += 1; continue
                case .other: skippedOther += 1; continue
                }
                let entry = "https://\(host)"
                if !hosts.contains(entry) { hosts.append(entry) }
            }
            SteamLog.event("[steam-cdn] selection=outbound-public-ip (Valve directory) offered=\(servers.count) usable=\(hosts.count) skipped-no-https=\(skippedHTTP) skipped-other=\(skippedOther)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SteamLog.trace("content directory failed: \(error.localizedDescription)")
        }
        let fallback = "https://steampipe.akamaized.net"
        if !hosts.contains(fallback) { hosts.append(fallback) }
        return hosts
    }

    nonisolated static func usableContentHost(_ host: String) -> Bool {
        guard host.contains("."), !host.contains(" "), !host.contains("/"), !host.contains("*"),
              !host.contains("lancache"), !host.contains(":") else { return false }
        return host.hasSuffix(".steamcontent.com") || host.hasSuffix(".akamaized.net") ||
            host.hasSuffix(".steampipe.steamcontent.com") || host.hasSuffix(".steamstatic.com")
    }

    /// Unified-service GetCDNAuthToken → "?auth=…" query fragment for this
    /// depot on this host. An empty token is normal outside regional edge
    /// networks. Cached per depot and host.
    private func cdnAuthFragment(depotID: UInt32, appID: UInt32, host: String) async -> String {
        let cacheKey = "\(depotID)|\(host)"
        if let cached = cdnAuthTokens[cacheKey] { return cached }

        // host_name must be the bare hostname, not the https:// URL
        let bareHost = URL(string: host)?.host ?? host

        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: depotID)  // depot_id = 1
        encoder.writeString(fieldNumber: 2, value: bareHost) // host_name = 2
        encoder.writeUInt32(fieldNumber: 3, value: appID)    // app_id = 3

        do {
            try await session.ensureConnected()
            let responseData = try await session.callServiceMethod(
                method: .getCDNAuthToken,
                body: encoder.data,
                timeout: 10
            )
            var decoder = ProtobufDecoder(responseData)
            var token = ""
            while let tag = try decoder.readTag() {
                if tag.fieldNumber == 1 { token = try decoder.readString() } else { try decoder.skip(wireType: tag.wireType) }
            }
            let fragment = token.isEmpty ? "" : (token.hasPrefix("?") || token.hasPrefix("&") ? token : "?auth=\(token)")
            cdnAuthTokens[cacheKey] = fragment
            return fragment
        } catch {
            SteamLog.trace("content authorization request failed; continuing without a token")
            cdnAuthTokens[cacheKey] = ""
            return ""
        }
    }
}

private final class SteamCDNRequestMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var measuredFirstByteSeconds: Double?

    var firstByteSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return measuredFirstByteSeconds
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last,
              let request = transaction.requestStartDate,
              let response = transaction.responseStartDate else { return }
        let latency = response.timeIntervalSince(request)
        guard latency.isFinite, latency >= 0 else { return }
        lock.lock()
        measuredFirstByteSeconds = latency
        lock.unlock()
    }
}

/// Append-only record of completed chunks for one depot manifest. Lines are
/// hexadecimal work-item keys. A lost tail only causes those chunks to be
/// fetched again.
final class JournalWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var pending = 0

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: url)
        // A previous attempt killed mid-write can leave a partial last line;
        // start on a fresh line so the first new key is not glued onto it.
        let end = handle.seekToEndOfFile()
        if end > 0 {
            handle.seek(toFileOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { buffer = "\n" }
            handle.seekToEndOfFile()
        }
    }

    func append(_ key: UInt64) {
        buffer += String(key, radix: 16) + "\n"
        pending += 1
        if pending >= 64 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""; pending = 0
    }

    func close() {
        flush()
        try? handle.close()
    }

    static func load(_ url: URL) -> Set<UInt64> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var keys = Set<UInt64>()
        for line in text.split(separator: "\n") { if let key = UInt64(line, radix: 16) { keys.insert(key) } }
        return keys
    }
}
