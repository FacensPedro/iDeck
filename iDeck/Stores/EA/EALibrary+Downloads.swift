// EALibrary: install, update, repair and the download queue.
// Split from EALibrary.swift (iDeck 3.0 architecture).

import Foundation

extension EALibrary {
    func install(_ id: String) { enqueue(id, kind: installed[id] == nil ? .install : .update) }

    func repair(_ id: String) { enqueue(id, kind: .repair) }

    func enqueue(_ id: String, kind: Download.Kind) {
        guard signedIn || installed[id] != nil else { error = "Sign in to EA to download games."; return }
        if kind == .install, let client = SystemCoordinator.StoreClient.required(for: ["Electronic Arts"], title: game(id)?.title ?? ""),
           client.installedURL == nil { error = client.installInstruction; return }
        if kind == .install, AntiCheatPolicy.isBlocked(title: game(id)?.title ?? "") { error = AntiCheatPolicy.message; return }
        guard signedIn else { error = EAAPIError.signedOut.localizedDescription; return }
        if let current = downloads[id], current.state == .active || current.state == .queued { return }
        // A resumed download keeps what it showed when it was paused.
        var download = Download(kind: kind, state: .queued)
        if let previous = downloads[id], previous.kind == kind, previous.state == .paused { download.progress = previous.progress }
        downloads[id] = download
        if !queue.contains(id) { queue.append(id) }
        startTimer()
        pump()
    }

    /// Stops a download, keeping its finished files; Resume continues from them.
    func pause(_ id: String) {
        if let current = active, current.id == id {
            current.task.cancel()
            // Shown as paused at once: the task stops at its next chunk.
            downloads[id]?.state = .paused
        } else if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
            downloads[id]?.state = .paused
        }
        resumeAfterSession.remove(id); resumeAfterBackground.remove(id)
    }

    /// Stop download: removes a first install's partial files and uninstalls an
    /// installed game whose update or repair is stopped.
    func cancel(_ id: String) {
        pause(id)
        let kind = downloads[id]?.kind ?? .install
        downloads[id] = nil
        if kind == .install { removePartialInstall(id) }
        EALog.event("[ea-download] cancelled id=\(id) kind=\(kind.rawValue)")
        if kind != .install, installed[id] != nil { uninstall(id) }
    }

    /// A first install's partial files: its folder (named in the journal's sidecar) and
    /// the journal. Used by Stop and, since 2.13.3, when the download fails.
    private func removePartialInstall(_ id: String) {
        let journal = Self.journalURL(id)
        let sidecar = journal.deletingPathExtension().appendingPathExtension("folder")
        if let folder = try? String(contentsOf: sidecar, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty,
           folder.hasPrefix(Self.installRoot + "/") {
            try? FileManager.default.removeItem(at: Self.drive.appendingPathComponent(folder, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: sidecar)
        try? FileManager.default.removeItem(at: journal)
    }

    /// Deletes the game's files and records; its library entry goes with them.
    func uninstall(_ id: String) {
        pause(id)
        downloads[id] = nil
        guard let record = installed[id] else { return }
        if record.folder.hasPrefix(Self.installRoot + "/") {
            try? FileManager.default.removeItem(at: Self.drive.appendingPathComponent(record.folder, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: Self.filesURL(id))
        try? FileManager.default.removeItem(at: Self.journalURL(id))
        installed[id] = nil
        writeInstalled()
        EALog.event("[ea-library] uninstalled id=\(id)")
    }

    private func pump() {
        guard active == nil, !inSession, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        downloads[id]?.state = .active
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(id)
        }
        active = (id, task)
    }

    func run(_ id: String) async {
        let kind = downloads[id]?.kind ?? .install
        do {
            let game = self.game(id)
            guard let title = game?.title ?? installed[id]?.title else { throw EAAPIError.invalid("unknown-game") }
            func step(_ text: String) {
                downloads[id]?.progress.step = text
                EALog.event("[ea-download] prepare id=\(id) step=\"\(text)\"")
            }
            step("Finding the newest build")
            let build = try await api.liveBuild(offerID: id)
            step("Getting the download address")
            let url = try await api.downloadURL(offerID: id, buildID: build.buildID)
            step("Reading the build's file list")
            var archive = try await downloader.archive(url)
            // The game page shows the size as soon as the file list is read.
            sizes[id] = .known(download: archive.compressedBytes, install: archive.installBytes)
            step("Choosing the fastest server")
            archive = await downloader.fastestMirror(archive)
            let record = installed[id]
            let folder = record?.folder ?? (Self.installRoot + "/" + Self.safeName(game?.installFolder ?? title))
            try? FileManager.default.createDirectory(at: Self.journalURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? folder.write(to: Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder"), atomically: true, encoding: .utf8)
            let previousData = try? Data(contentsOf: Self.filesURL(id))
            let previous = previousData.flatMap { try? JSONDecoder().decode([EAZipEntry].self, from: $0) }
            EALog.event("[ea-download] start id=\(id) kind=\(kind.rawValue) build=\(build.buildID) files=\(archive.files.count) bytes=\(archive.compressedBytes)")
            let result = try await downloader.install(
                archive: archive, folder: Self.drive.appendingPathComponent(folder, isDirectory: true),
                previous: kind == .repair ? nil : previous, verifyAll: kind == .repair, journal: Self.journalURL(id)) { progress in
                    guard ProgressThrottle.allow("ea:" + id, state: "\(progress.phase)\(progress.step ?? "")",
                                                 done: progress.doneBytes, total: progress.totalBytes) else { return }
                    Task { @MainActor in EALibrary.shared.downloads[id]?.progress = progress }
                    if progress.phase == .downloading {
                        DownloadLog.progress(store: "EA app", name: title, done: progress.doneBytes, total: progress.totalBytes)
                    }
                }
            try? FileManager.default.createDirectory(at: Self.filesURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(archive.entries).write(to: Self.filesURL(id), options: .atomic)
            try? FileManager.default.removeItem(at: Self.journalURL(id).deletingPathExtension().appendingPathExtension("folder"))
            let launch = try Self.launch(folder: Self.drive.appendingPathComponent(folder, isDirectory: true), catalogPath: game?.executePath)
            let finished = EAInstalledGame(
                offerID: id, title: title, folder: folder, buildID: build.buildID, version: launch.version ?? build.version,
                contentID: game?.contentID ?? launch.contentID ?? record?.contentID ?? "", multiplayerID: game?.multiplayerID ?? record?.multiplayerID ?? "",
                launchExe: launch.exe, arguments: launch.arguments, installBytes: result.installBytes,
                registryKey: launch.registryKey, registryValue: launch.registryValue)
            if finished.contentID.isEmpty { EALog.event("[ea-download] id=\(id): no content id (licence requests will not work)") }
            installed[id] = finished
            latestBuild[id] = build.buildID
            writeInstalled()
            downloads[id] = nil
            Self.writeRegistry(finished)
            EALog.event("[ea-download] done id=\(id) written=\(result.filesWritten) kept=\(result.filesKept) fetched=\(result.bytesFetched)")
            DownloadLog.ended(store: "EA app", name: title, outcome: "finished")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                let stopped = downloads[id] == nil
                if downloads[id]?.state != .queued { downloads[id]?.state = .paused }
                EALog.event("[ea-download] \(stopped ? "stopped" : "paused") id=\(id)")
                DownloadLog.ended(store: "EA app", name: game(id)?.title ?? installed[id]?.title ?? id, outcome: stopped ? "stopped" : "paused")
            } else {
                downloads[id]?.state = .failed(error.localizedDescription)
                // A failed first install is removed, as Stop does: no half game is left.
                if downloads[id]?.kind == .install && installed[id] == nil {
                    removePartialInstall(id)
                    EALog.event("[ea-download] failed id=\(id): partial files removed")
                }
                DownloadLog.ended(store: "EA app", name: game(id)?.title ?? installed[id]?.title ?? id, outcome: "failed: " + error.localizedDescription)
                handle(error, context: "download id=\(id)", report: false)
            }
        }
        active = nil
        pump()
        if !hasActiveDownload { ResourceGovernor.shared.releaseAfterDownload() }
    }
}
