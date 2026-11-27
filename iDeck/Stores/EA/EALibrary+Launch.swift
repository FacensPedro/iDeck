// EALibrary: licence, launch environment and the game session.
// Split from EALibrary.swift (iDeck 3.0 architecture).

import Foundation
import UIKit

extension EALibrary {
    struct Launch: Equatable {
        var exe: String          // relative to the game's folder, forward slashes
        var arguments: String
        var version: String?
        var contentID: String?
        var registryKey: String?
        var registryValue: String?
    }

    /// How the EA app starts the game: the launcher of `__Installer/installerdata.xml`,
    /// else the catalog's program. A path behind a registry key is taken relative to the
    /// game's folder, and the key is remembered for the registry.
    nonisolated static func launch(folder: URL, catalogPath: String?) throws -> Launch {
        var data: EAInstallerData?
        if let installer = EALicense.child(of: folder, named: "__Installer"), let file = EALicense.child(of: installer, named: "installerdata.xml"),
           let bytes = try? Data(contentsOf: file) {
            data = EAInstallerData.parse(bytes)
        }
        guard let text = data?.launcher?.filePath ?? catalogPath else { throw EAAPIError.noLauncher }
        let path = EARegistryPath(text)
        let relative = path.relative.replacingOccurrences(of: "\\", with: "/")
        guard let parts = EAZipDirectory.safeComponents(relative), !parts.isEmpty else { throw EAAPIError.noLauncher }
        let exe = parts.joined(separator: "/")
        guard EALicense.child(of: parts.dropLast().reduce(folder) { $0.appendingPathComponent($1) }, named: parts.last!) != nil else {
            EALog.event("[ea-library] launcher not found: \(exe)")
            throw EAAPIError.noLauncher
        }
        return Launch(exe: exe, arguments: data?.launcher?.parameters ?? "", version: data?.gameVersion, contentID: data?.contentIDs.first,
                      registryKey: path.key, registryValue: path.valueName)
    }

    nonisolated static func hashVariant(contentID: String) -> Int {
        UserDefaults.standard.integer(forKey: hashVariantPrefix + contentID)
    }

    /// The session of the last prepared EA game ended; `activationUI` says whether its
    /// Wine log shows ActivationUI.exe, EA's activation window, being started.
    nonisolated static func noteSessionEnded(activationUI: Bool) {
        guard let content = lastPreparedContentID else { return }
        lastPreparedContentID = nil
        let variant = hashVariant(contentID: content)
        guard activationUI else {
            EALog.event("[ea-license] content=\(content) accepted its licence (hash variant \(variant))")
            return
        }
        UserDefaults.standard.set(true, forKey: "ea.traceActivation.ea:" + (lastPreparedOfferID ?? content))
        let next = variant == 0 ? 1 : 0
        UserDefaults.standard.set(next, forKey: hashVariantPrefix + content)
        EALog.event("[ea-license] content=\(content) started ActivationUI.exe with hash variant \(variant) "
            + "(\(variant == 0 ? "display adapter hashed" : "no display adapter")): the next launch asks for a licence with variant \(next)")
        // EA's activation window writes why it opened in C:\ProgramData\Origin\Logs; the
        // game itself says nothing, so those lines go in iDeck's log.
        let account = EAAPI.shared.account()
        let hidden = [account?.displayName, account?.userID, account?.personaID].compactMap { $0 }
        let reason = EAPrefixEvidence.activationReason(
            drive: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wine/drive_c", isDirectory: true),
            hidden: hidden)
        if reason.isEmpty {
            EALog.event("[ea-activation-log] EA's activation window left no log in C:\\ProgramData\\Origin\\Logs")
        }
        for line in reason { EALog.event("[ea-activation-log] " + line.trimmingCharacters(in: .whitespaces)) }
    }

    /// The activation library the game ships and what the licence is built for.
    nonisolated static func activationFacts(_ activation: EALicense.Activation, gameFolder: URL) -> String {
        guard activation.required else { return "no Core folder: the game checks no licence" }
        let core = EALicense.child(of: gameFolder, named: "Core")
        let names = (core.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []).sorted()
        let version = activation.libraryVersion.map { "\($0.major).\($0.minor).\($0.patch)" } ?? "unreadable"
        // A 64-bit game loads Activation64.dll; the hash version is read from Activation.dll,
        // as the EA app does. Both versions are named so a difference shows.
        var wide = ""
        if let core, let library = EALicense.child(of: core, named: "Activation64.dll"),
           let data = try? Data(contentsOf: library, options: .mappedIfSafe) {
            wide = " (Activation64.dll " + (EAPEVersion.productVersion(data).map { "\($0.major).\($0.minor).\($0.patch)" } ?? "unreadable") + ")"
        }
        return "library \(version)\(wide), hash version \(activation.hashVersion), signature as \(activation.decodeSignature ? "bytes" : "base64 text"), "
            + "Core: \(names.prefix(16).joined(separator: " "))"
    }

    /// The registry keys an EA game expects: the EA app's install marker and, when the
    /// game's manifest named one, its own install folder. Only while no session runs.
    nonisolated static func writeRegistry(_ record: EAInstalledGame) {
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        var values = [
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\EA Desktop", name: "InstallSuccessful", data: .string("true"), followsInstall: false),
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\Origin", name: "InstallSuccessful", data: .string("true"), followsInstall: false),
            SteamInstallValue(hive: .machine, key: "Software\\Electronic Arts\\Origin", name: "ClientPath",
                              data: .string("C:\\Windows\\System32\\conhost.exe"), followsInstall: false),
        ]
        if let key = record.registryKey, let name = record.registryValue, !key.isEmpty {
            values.append(SteamInstallValue(hive: .machine, key: key, name: name, data: .string(record.windowsInstallPath + "\\"), followsInstall: true))
        }
        do {
            let changed = try EARegistry.write(values, prefix: MadeiraDock.prefix)
            EALog.event("[ea-library] registry values=\(values.count) written=\(changed) game-key=\(record.registryKey == nil ? 0 : 1)")
        } catch {
            EALog.event("[ea-library] registry write failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func clearEnvironment() {
        for name in environmentNames { unsetenv(name) }
    }

    /// Everything an EA game needs before its session starts: a valid sign-in, its
    /// licence for this machine, the registry keys, the EA app's environment and the
    /// local service. Throws with a message for the player when something is missing.
    func prepareLaunch(offerID id: String, nvidiaGPU nvidia: Bool = false, avx: Bool = false) async throws {
        guard let record = installed[id] else { throw EAAPIError.invalid("not-installed") }
        let session: EASession
        do { session = try await api.validSession() } catch {
            handle(error, context: "launch id=\(id)", report: false)
            throw error
        }
        // The GPU Madeira's Wine reports (build/win32u-unix/sysparams_ios.c): the NVIDIA
        // card the game's setting picks, otherwise the device's own.
        let profile = EAHardware.profile(drive: Self.drive, gpuVendor: nvidia ? Self.nvidiaVendor : Self.appleVendor,
                                         gpuDevice: nvidia ? 0x2544 : 0x0001, avx: avx)
        let folder = Self.drive.appendingPathComponent(record.folder, isDirectory: true)
        let activation = EALicense.activation(gameFolder: folder)
        var licenceProfile = profile
        // What the licence was prepared for, kept for the bug report: a game that does
        // not accept it starts EA's activation window, and only these facts say why.
        let facts = Self.activationFacts(activation, gameFolder: folder)
        UserDefaults.standard.set(facts + ", licence not prepared", forKey: Self.licenceFactsKey)
        // As a GOG game runs offline when iDeck cannot answer as GOG Galaxy, a licence
        // iDeck cannot prepare no longer stops the launch: the game starts and its own
        // activation decides (EA's activation window, or the game runs).
        if activation.required && record.contentID.isEmpty {
            EALog.event("[ea-license] id=\(id): no content id; starting without a prepared licence")
            UserDefaults.standard.set(facts + ", licence not prepared (no content id)", forKey: Self.licenceFactsKey)
        } else if activation.required {
            Self.lastPreparedContentID = record.contentID
            Self.lastPreparedOfferID = id
            // See hashVariantPrefix: variant 1 is the hash taken before Wine registered the
            // display adapter. The licence and the local service use it; the launch token keeps the device.
            let variant = Self.hashVariant(contentID: record.contentID)
            if variant == 1 { licenceProfile.gpuPNPDeviceID = "" }
            EALog.event("[ea-license] content=\(record.contentID) hash variant \(variant)")
            let (hash, _) = licenceProfile.machineHash(version: activation.hashVersion)
            UserDefaults.standard.set(EAHashCheck.report(profile: licenceProfile, hashVersion: activation.hashVersion, drive: Self.drive),
                                      forKey: Self.hashCheckKey)
            let current = EALicense.current(contentID: record.contentID, drive: Self.drive)
            // Every launch asks EA for a fresh licence. A licence kept from an earlier
            // launch (same machine hash, still recent) was refused by Dragon Age:
            // Inquisition, which then started ActivationUI.exe; the same game accepted a
            // renewed one. A kept licence is used only when the renewal fails.
            let stale = EALicense.needsRenewal(current, machineHash: hash, userID: session.userID)
            var renewal: EALicenseInfo?
            UserDefaults.standard.set(facts + ", licence request failed", forKey: Self.licenceFactsKey)
            do {
                renewal = try await EALicense.renew(api: api, contentID: record.contentID, profile: licenceProfile, activation: activation, drive: Self.drive)
            } catch {
                EALog.event("[ea-license] renewal failed content=\(record.contentID) stale=\(stale ? 1 : 0): \(error.localizedDescription)"
                            + (stale ? "; starting with the kept licence, the game's activation decides" : ""))
            }
            if let renewed = renewal {
                UserDefaults.standard.set(facts + ", licence renewed, game token \(renewed.gameToken == nil ? "absent" : "present")",
                                          forKey: Self.licenceFactsKey)
            } else {
                UserDefaults.standard.set(facts + ", licence kept (renewal failed), game token \(current?.gameToken == nil ? "absent" : "present")",
                                          forKey: Self.licenceFactsKey)
                EALog.event("[ea-license] kept content=\(record.contentID) hash-version=\(activation.hashVersion)")
            }
        } else {
            UserDefaults.standard.set(facts, forKey: Self.licenceFactsKey)
        }
        Self.writeRegistry(record)
        // The short-lived token the EA app hands a game (EALaunchUserAuthToken); a game
        // that never reads it still starts, so a failure here is logged, not fatal.
        var opaque = ""
        do {
            opaque = try await api.exchange(clientID: EAAPI.clientID, responseType: "token",
                                            scopes: ["basic.commerce.cartv2", "service.atom", "dp.client.default", "signin", "social_recommendation_user",
                                                     "basic.optin.write", "basic.commerce.cartv2.write", "basic.billing", "external.social_information_ups_admin"],
                                            tokenFormat: "OPAQUE", expiresIn: 550, profile: profile)
        } catch {
            handle(error, context: "launch token id=\(id)", report: false)
        }
        let launchID = UUID().uuidString.lowercased()
        let environment: [String: String] = [
            "EAAuthCode": "unavailable", "EAEgsProxyIpcPort": "0", "EAEntitlementSource": "EA", "EAExternalSource": "EA", "EAFreeTrialGame": "false",
            "EAGameLocale": GameLanguage.locale("ea:" + id, separator: "_"), "EAGenericAuthToken": session.accessToken, "EALaunchCode": "unavailable", "EALaunchOwner": "EA",
            "EALaunchEAID": session.displayName, "EALaunchEnv": "production", "EALaunchOfflineMode": "false", "EALsxPort": String(EAService.port),
            "EARtPLaunchCode": String(EALSXCrypto.launchCode()), "EASecureLaunchTokenTemp": session.userID, "EASteamProxyIpcPort": "0",
            "OriginSessionKey": launchID, "ContentId": record.contentID, "EAOnErrorExitRetCode": "1", "EAConnectionId": id, "EALicenseToken": id,
            "EALaunchUserAuthToken": opaque, "EAAccessTokenJWS": session.accessToken,
        ]
        Self.clearEnvironment()
        for (name, value) in environment { setenv(name, value, 1) }
        try EAService.shared.start(EAServiceContext(
            offerID: id, contentID: record.contentID, title: record.title, version: record.version, multiplayerID: record.multiplayerID,
            userID: session.userID, personaID: session.personaID, displayName: session.displayName, profile: licenceProfile, hashVersion: activation.hashVersion))
        launched = id
        startTimer()
        let hasUserToken = !opaque.isEmpty
        EALog.event("[ea-launch] id=\(id) content=\(record.contentID) licence=\(activation.required ? "checked" : "none") token=\(hasUserToken ? 1 : 0)")
    }

    /// The session ended: the service stops and the EA app's environment goes.
    func launchEnded() {
        guard launched != nil else { return }
        launched = nil
        EAService.shared.stop()
        Self.clearEnvironment()
    }

    /// A game session is starting or ended: downloads pause for it and continue afterwards. Idempotent.
    func sessionChanged(active running: Bool) {
        guard running != inSession else { return }
        if !running { launchEnded() }
        inSession = running
        if running {
            if let current = active { resumeAfterSession.insert(current.id); current.task.cancel() }
            for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
            if !resumeAfterSession.isEmpty { EALog.event("[ea-download] paused for a game session count=\(resumeAfterSession.count)") }
        } else {
            let resume = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for id in resume { enqueue(id, kind: downloads[id]?.kind ?? .install) }
        }
    }

    func reconcileSession() { sessionChanged(active: sessionRunning) }

    func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileSession()
                if !self.hasActiveDownload, self.launched == nil { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    func beginGrace() {
        guard hasActiveDownload, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "EA download") { [weak self] in
            MainActor.assumeIsolated {
                self?.pauseForBackground()
                self?.endGrace()
            }
        }
    }

    func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    private func pauseForBackground() {
        if let current = active { resumeAfterBackground.insert(current.id); current.task.cancel() }
        for id in queue { resumeAfterBackground.insert(id); downloads[id]?.state = .paused }
        queue.removeAll()
        EALog.event("[ea-download] paused for the background count=\(resumeAfterBackground.count)")
    }

    func resumeFromBackground() {
        let ids = resumeAfterBackground.sorted()
        resumeAfterBackground.removeAll()
        for id in ids { enqueue(id, kind: downloads[id]?.kind ?? .install) }
    }
}
