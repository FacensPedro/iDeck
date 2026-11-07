// SPDX-License-Identifier: GPL-3.0-or-later
// Ported from willfaust/Madeira app/Madeira/SwiftGOG/GOGGalaxy.swift (8b52c18),
// GPL-3.0-or-later with the Madeira Converter Exception (LICENSES/).
// iDeck changes: iDeck's GOG library and sign-in, the game's Galaxy client read from
// its build manifest at launch, the service registered in iDeck's Wine prefix.

import Foundation

// GOG Galaxy's game services for a GOG game's play: a game built with GOG's Galaxy
// SDK talks to GOG's client on 127.0.0.1:9977 for its sign-in, achievements, stats,
// leaderboards and play time. While a GOG game runs, iDeck answers there itself
// (GalaxyListener and GalaxyService, ported from Madeira/Playport), with a token GOG
// mints for that game's own client from iDeck's GOG sign-in (per-game
// authentication: the game never sees iDeck's own tokens). Some SDK versions first
// ask Windows to start the "GalaxyCommunication" service, so the prefix gets a
// do-nothing service of that name (build/gog-galaxy-service). Without a sign-in, a
// Galaxy client or a free port, the game runs offline, as a GOG game does without
// GOG's client. Log tag: [galaxy] (request names and statuses only; never a token).

@MainActor final class GOGGalaxy {
    static let shared = GOGGalaxy()

    /// Where GOG's own client and Heroic's comet put the service's program.
    static let serviceWindowsPath = "C:\\ProgramData\\GOG.com\\Galaxy\\redists\\GalaxyCommunication.exe"
    static let serviceRelativePath = "ProgramData/GOG.com/Galaxy/redists/GalaxyCommunication.exe"
    /// Wine keeps CurrentControlSet as a link to ControlSet001 in system.reg.
    static let serviceKey = "System\\ControlSet001\\Services\\GalaxyCommunication"

    private var listener: GalaxyListener?
    private var clients: [Int: GOGGalaxyClient] = [:]

    private init() {}

    /// Right before a GOG game starts, while no session runs: registers the
    /// GalaxyCommunication service and starts the local Galaxy service with this
    /// game's own client. Stops any earlier one.
    func prepare(gameID: Int, drive: URL) async {
        stop()
        registerService(drive: drive)
        guard let tokens = GOGTokenStore.load() else {
            AppLog.record("[galaxy] not signed in to GOG; id=\(gameID) runs offline")
            return
        }
        let client: GOGGalaxyClient
        if let known = clients[gameID] {
            client = known
        } else {
            do {
                let fresh = tokens.isExpired ? try await GOGAPI.refresh(tokens) : tokens
                if fresh != tokens { GOGTokenStore.save(fresh) }
                guard let found = try await GOGContentSystem.galaxyClient(gameID: gameID, tokens: fresh) else {
                    AppLog.record("[galaxy] id=\(gameID) has no Galaxy client; it runs offline")
                    return
                }
                clients[gameID] = found
                client = found
            } catch {
                AppLog.record("[galaxy] id=\(gameID) client not read (\(error.localizedDescription)); it runs offline")
                return
            }
        }
        let log = GalaxyLogger { line in AppLog.record(line) }
        let listener = GalaxyListener(service: GalaxyService(client: client, tokens: IDeckGalaxyTokens(), log: log), log: log)
        do {
            try listener.start()
        } catch {
            AppLog.record("[galaxy] not started for id=\(gameID): \(error); the game runs offline")
            return
        }
        self.listener = listener
        AppLog.record("[galaxy] serving id=\(gameID) on 127.0.0.1:9977")
    }

    func stop() {
        guard let listener else { return }
        listener.stop()
        self.listener = nil
        AppLog.record("[galaxy] stopped")
    }

    /// The GalaxyCommunication service in the prefix: its program and registry key.
    /// Only while no session runs (the wineserver holds the registry then).
    private func registerService(drive: URL) {
        guard wineserver_is_running() == 0, wine_process_is_running() == 0 else { return }
        guard let bundled = Bundle.main.url(forResource: "madeira-galaxy-service", withExtension: "exe") else {
            AppLog.record("[galaxy] GalaxyCommunication service program is not in this build")
            return
        }
        let target = drive.appendingPathComponent(Self.serviceRelativePath)
        let fm = FileManager.default
        do {
            let data = try Data(contentsOf: bundled)
            if (try? Data(contentsOf: target)) != data {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            let values: [SteamInstallValue] = [
                .init(hive: .machine, key: Self.serviceKey, name: "DisplayName", data: .string("GalaxyCommunication"), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "ImagePath", data: .string("\"" + Self.serviceWindowsPath + "\""), followsInstall: true),
                .init(hive: .machine, key: Self.serviceKey, name: "ObjectName", data: .string("LocalSystem"), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "Type", data: .dword(0x10), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "Start", data: .dword(3), followsInstall: false),
                .init(hive: .machine, key: Self.serviceKey, name: "ErrorControl", data: .dword(1), followsInstall: false),
            ]
            let changed = try EARegistry.write(values, prefix: drive.deletingLastPathComponent())
            if changed > 0 { AppLog.record("[galaxy] GalaxyCommunication service registered values=\(changed)") }
        } catch {
            AppLog.record("[galaxy] GalaxyCommunication service not registered: \(error.localizedDescription)")
        }
    }
}
