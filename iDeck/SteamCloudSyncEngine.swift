// SPDX-License-Identifier: GPL-3.0-or-later
// Steam Cloud sync layer for iDeck. Uses Madeira's SteamCloud primitives.
import CryptoKit
import Foundation

@MainActor
final class SteamCloudSyncEngine {
    struct Result {
        var downloaded: Int
        var uploaded: Int
        var conflicts: Int
        var message: String
    }

    private struct Record: Codable {
        var account: String
        var apps: [String: [String: String]]
    }

    private let session: SteamCMSession
    private var baselineCache: Record?
    private var busyApps = Set<UInt32>()
    private var conflictedSaves: [UInt32: [SteamCloudEntry]] = [:]

    init(session: SteamCMSession) {
        self.session = session
    }

    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck/SteamCloud/sync-baseline.json")
    }

    private func baseline(appID: UInt32) -> [String: String] {
        let account = SteamSignIn.accountName ?? ""
        if baselineCache?.account != account {
            if let file = try? Data(contentsOf: storageURL), file.count <= 16 << 20,
               let decoded = try? JSONDecoder().decode(Record.self, from: file),
               decoded.account == account {
                baselineCache = decoded
            } else {
                baselineCache = Record(account: account, apps: [:])
            }
        }
        return baselineCache?.apps[String(appID)] ?? [:]
    }

    private func settle(appID: UInt32, _ hashes: [String: String]) {
        guard !hashes.isEmpty else { return }
        var previous = baseline(appID: appID)
        var changed = false
        for (key, value) in hashes where previous[key] != value {
            previous[key] = value
            changed = true
        }
        guard changed else { return }
        baselineCache?.apps[String(appID)] = previous
        let folder = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let baselineCache {
            try? JSONEncoder().encode(baselineCache).write(to: storageURL, options: .atomic)
        }
    }

    private func cloudContext(appID: UInt32, info: SteamAppInfo,
                              prefixPath: URL) throws -> SteamCloudPaths {
        let drive = prefixPath.appendingPathComponent("drive_c", isDirectory: true)
        guard let user = SteamCloudPaths.userFolder(drive: drive) else {
            throw SteamFileError.invalid("A pasta do usuário Wine ainda não existe. Configure o prefixo Windows antes de sincronizar os saves.")
        }
        let apps = SteamInstallPaths.steamApps(drive: drive)
        let folder = SteamInstallFiles.installDirectoryName(
            appID: Int(appID), steamApps: apps) ??
            SteamInstallFiles.safeFolderName(info.installDir)
        let clientRoot = apps.deletingLastPathComponent()
        return SteamCloudPaths(
            drive: drive, userFolder: user.url,
            installFolder: apps.appendingPathComponent("common", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true),
            remoteFolder: clientRoot.appendingPathComponent(
                "userdata/\(session.steamID & 0xFFFF_FFFF)/\(appID)/remote", isDirectory: true),
            steamID: session.steamID, overrides: info.rootOverrides)
    }

    private func listing(appID: UInt32) async throws -> SteamCloudListing {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: appID)
        request.writeUInt64(fieldNumber: 2, value: 0)
        let response = try await session.callServiceMethod(
            method: .cloudGetAppFileChangelist, body: request.data, timeout: 25)
        return try SteamCloudListing.parse(response)
    }

    private func downloadFile(appID: UInt32, entry: SteamCloudEntry) async throws -> Data {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: appID)
        request.writeString(fieldNumber: 2, value: entry.path)
        let response = try await session.callServiceMethod(
            method: .cloudClientFileDownload, body: request.data, timeout: 25)
        return try await SteamCloudTransfer.fetch(
            SteamCloudDownloadInfo.parse(response), expectedSHA: entry.cloudSHA)
    }

    private func validLocation(_ entry: SteamCloudEntry, paths: SteamCloudPaths)
        throws -> (file: URL, relative: [String]) {
        guard let location = paths.location(cloudPath: entry.path) else {
            throw SteamFileError.invalid("O caminho deste save não é compatível com o Windows.")
        }
        let base = location.base.standardizedFileURL.resolvingSymlinksInPath()
        let file = SteamCloudPaths.resolve(base: base, parts: location.parts)
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/"), location.parts.count <= 32 else {
            throw SteamFileError.invalid("Um save tentou acessar uma pasta fora do prefixo Windows.")
        }
        return (file, location.parts)
    }

    private func backups(appID: UInt32, side: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Steam Cloud Backups/\(appID)/\(stamp)/\(side)", isDirectory: true)
    }

    private func download(appID: UInt32, entries: [SteamCloudEntry],
                          paths: SteamCloudPaths) async throws -> Int {
        let backup = backups(appID: appID, side: "device")
        var settled = [String: String]()
        var count = 0
        for entry in entries {
            try Task.checkCancellation()
            let location = try validLocation(entry, paths: paths)
            let data = try await downloadFile(appID: appID, entry: entry)
            let root = SteamCloudPaths.split(entry.path).root ?? "remote"
            try SteamCloudTransfer.place(data, at: location.file, backupTo: backup,
                                         relative: [root] + location.relative,
                                         time: entry.cloudTime)
            settled[entry.key] = SteamCloudPlan.hex(entry.cloudSHA)
            count += 1
        }
        settle(appID: appID, settled)
        return count
    }

    private var clientID: UInt64 {
        let key = "iDeck.steamCloud.clientID"
        if let stored = UserDefaults.standard.string(forKey: key),
           let id = UInt64(stored), id > 0 { return id }
        let id = UInt64.random(in: 1...UInt64(Int64.max))
        UserDefaults.standard.set(String(id), forKey: key)
        return id
    }

    private func upload(appID: UInt32, entries: [SteamCloudEntry],
                        paths: SteamCloudPaths, buildID: UInt32) async throws -> Int {
        guard !entries.isEmpty else { return 0 }
        // Back up existing remote copies before overwriting them.
        let backup = backups(appID: appID, side: "cloud")
        for entry in entries where !entry.cloudSHA.isEmpty {
            let location = try validLocation(entry, paths: paths)
            let old = try await downloadFile(appID: appID, entry: entry)
            var target = backup.appendingPathComponent(
                SteamCloudPaths.split(entry.path).root ?? "remote", isDirectory: true)
            for part in location.relative { target.appendPathComponent(part) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try old.write(to: target, options: .atomic)
        }

        var begin = ProtobufEncoder()
        begin.writeUInt32(fieldNumber: 1, value: appID)
        begin.writeString(fieldNumber: 2, value: "iDeck")
        for entry in entries { begin.writeString(fieldNumber: 3, value: entry.path) }
        begin.writeUInt64(fieldNumber: 5, value: clientID)
        begin.writeUInt64(fieldNumber: 6, value: UInt64(buildID))
        var decoder = ProtobufDecoder(try await session.callServiceMethod(
            method: .cloudBeginAppUploadBatch, body: begin.data, timeout: 30))
        var batchID: UInt64 = 0
        while let field = try decoder.readTag() {
            if field.fieldNumber == 1 && field.wireType == .varint {
                batchID = try decoder.readVarint()
            } else {
                try decoder.skip(wireType: field.wireType)
            }
        }
        guard batchID != 0 else {
            throw SteamFileError.invalid("Steam Cloud não autorizou a transferência de saves.")
        }

        func complete(_ ok: Bool) async {
            var request = ProtobufEncoder()
            request.writeUInt32(fieldNumber: 1, value: appID)
            request.writeUInt64(fieldNumber: 2, value: batchID)
            request.writeUInt32(fieldNumber: 3, value: ok ? 1 : 2)
            _ = try? await session.callServiceMethod(
                method: .cloudCompleteAppUploadBatch, body: request.data, timeout: 30)
        }

        var count = 0
        do {
            for entry in entries {
                try Task.checkCancellation()
                let location = try validLocation(entry, paths: paths)
                let data = try Data(contentsOf: location.file)
                guard data.count <= SteamCloudTransfer.maxFileBytes else {
                    throw SteamFileError.invalid("Save excede o limite por arquivo do Steam Cloud.")
                }
                let sha = Data(Insecure.SHA1.hash(data: data))
                let time = UInt64(max(0, (try? location.file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate?
                        .timeIntervalSince1970 ?? Date().timeIntervalSince1970))
                var request = ProtobufEncoder()
                request.writeUInt32(fieldNumber: 1, value: appID)
                request.writeUInt32(fieldNumber: 2, value: UInt32(data.count))
                request.writeUInt32(fieldNumber: 3, value: UInt32(data.count))
                request.writeBytes(fieldNumber: 4, value: sha)
                request.writeUInt64(fieldNumber: 5, value: time)
                request.writeString(fieldNumber: 6, value: entry.path)
                request.writeUInt32(fieldNumber: 7, value: UInt32.max)
                request.writeUInt32(fieldNumber: 9, value: session.cellID)
                request.writeUInt64(fieldNumber: 13, value: batchID)
                let response = try await session.callServiceMethod(
                    method: .cloudClientBeginFileUpload, body: request.data, timeout: 30)
                let details = try SteamCloudUploadBlock.parse(response)
                guard !details.encrypt else {
                    throw SteamFileError.invalid("Steam exige criptografia de upload não suportada.")
                }
                let status = try await SteamCloudTransfer.send(data, blocks: details.blocks)
                guard status.allSatisfy({ (200..<300).contains($0) }) else {
                    throw SteamFileError.invalid("Steam rejeitou um bloco do save.")
                }
                var commit = ProtobufEncoder()
                commit.writeBool(fieldNumber: 1, value: true)
                commit.writeUInt32(fieldNumber: 2, value: appID)
                commit.writeBytes(fieldNumber: 3, value: sha)
                commit.writeString(fieldNumber: 4, value: entry.path)
                var reply = ProtobufDecoder(try await session.callServiceMethod(
                    method: .cloudClientCommitFileUpload, body: commit.data, timeout: 30))
                var committed = false
                while let tag = try reply.readTag() {
                    if tag.fieldNumber == 1 && tag.wireType == .varint {
                        committed = try reply.readVarint() != 0
                    } else { try reply.skip(wireType: tag.wireType) }
                }
                guard committed else { throw SteamFileError.invalid("Steam não confirmou o save.") }
                count += 1
            }
            await complete(true)
        } catch {
            await complete(false)
            throw error
        }
        return count
    }

    func sync(appID: UInt32, info: SteamAppInfo, prefixPath: URL) async throws -> Result {
        guard busyApps.insert(appID).inserted else {
            throw SteamFileError.invalid("Uma sincronização deste jogo já está em andamento.")
        }
        defer { busyApps.remove(appID) }
        try Task.checkCancellation()
        try await session.ensureConnected()
        guard session.steamID != 0 else { throw SteamFileError.invalid("A Steam não está conectada.") }
        let paths = try cloudContext(appID: appID, info: info, prefixPath: prefixPath)
        let remote = try await listing(appID: appID)
        let saveFiles = info.saveFiles
        let audit = await Task.detached(priority: .utility) {
            SteamCloudAudit.run(listing: remote, saveFiles: saveFiles, paths: paths)
        }.value
        let plan = SteamCloudPlan.make(audit: audit, baseline: baseline(appID: appID))
        settle(appID: appID, plan.settled)
        var downloaded = 0
        var uploaded = 0
        // Only unambiguous changes are automatically synced. Never replace
        // a local or cloud save when the baseline is absent or both changed.
        if !plan.download.isEmpty {
            downloaded = try await download(appID: appID, entries: plan.download, paths: paths)
        }
        if !plan.upload.isEmpty {
            uploaded = try await upload(appID: appID, entries: plan.upload, paths: paths,
                                        buildID: info.buildID)
        }
        let after = try await listing(appID: appID)
        let reAudit = await Task.detached(priority: .utility) {
            SteamCloudAudit.run(listing: after, saveFiles: saveFiles, paths: paths)
        }.value
        let afterPlan = SteamCloudPlan.make(audit: reAudit, baseline: baseline(appID: appID))
        settle(appID: appID, afterPlan.settled)
        let conflicts = afterPlan.conflicts.count
        conflictedSaves[appID] = afterPlan.conflicts
        let message = "Steam Cloud: \(downloaded) save(s) baixado(s), \(uploaded) enviado(s)" +
            (conflicts > 0 ? "; \(conflicts) conflito(s) aguardando escolha." : ".")
        return Result(downloaded: downloaded, uploaded: uploaded,
                      conflicts: conflicts, message: message)
    }
    func resolve(appID: UInt32, info: SteamAppInfo, prefixPath: URL,
                 preferCloud: Bool) async throws -> Result {
        guard !busyApps.contains(appID),
              let conflicts = conflictedSaves[appID], !conflicts.isEmpty else {
            throw SteamFileError.invalid("Não há saves em conflito para este jogo.")
        }
        busyApps.insert(appID)
        let paths: SteamCloudPaths
        do {
            try await session.ensureConnected()
            paths = try cloudContext(appID: appID, info: info, prefixPath: prefixPath)
            if preferCloud {
                _ = try await download(appID: appID, entries: conflicts, paths: paths)
            } else {
                let missing = conflicts.filter { $0.kind == .cloudOnly }
                settle(appID: appID, Dictionary(missing.map { entry in
                    (entry.key, SteamCloudPlan.deletedMark + SteamCloudPlan.hex(entry.cloudSHA))
                }, uniquingKeysWith: { _, last in last }))
                let present = conflicts.filter { $0.kind != .cloudOnly }
                if !present.isEmpty {
                    _ = try await upload(appID: appID, entries: present, paths: paths,
                                         buildID: info.buildID)
                }
            }
        } catch {
            busyApps.remove(appID)
            throw error
        }
        busyApps.remove(appID)
        return try await sync(appID: appID, info: info, prefixPath: prefixPath)
    }

}
