// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Adapted for iDeck from Madeira's EALibrary.swift (willfaust/Madeira 8b52c18,
// GPL-3.0-or-later with the Madeira Converter Exception). Installed games are
// listed from `installed`, launches go through SystemCoordinator, and registry
// values are written by EARegistry.

import CryptoKit
import Foundation
import UIKit

// The EA app's library in Madeira (docs/EA.md): the signed-in account's PC
// games, what is installed, the download queue, and what a game needs to start
// (its licence, the EA app's environment and the local service the game talks
// to). EA's protocol work follows Maxima (GPL-3.0); no Maxima code is included.

@MainActor final class EALibrary: ObservableObject {
    static let shared = EALibrary()

    /// Off with `env.MADEIRA_EA = 0`.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_EA", default: true) }

    @Published var signedIn = false
    @Published var accountName: String? { didSet { PrivacyRedactor.register(accountName) } }
    @Published var owned: [EAOwnedGame] = []
    @Published var installed: [String: EAInstalledGame] = [:]
    @Published var refreshing = false
    @Published var libraryUpdated: Date?
    /// The newest build id seen for each installed game (checked when its page opens).
    @Published var latestBuild: [String: String] = [:]
    /// A game's download and installed size (the live build's archive), or why EA gave none.
    enum Size: Equatable { case known(download: Int64, install: Int64), unavailable(String) }
    @Published var sizes: [String: Size] = [:]
    @Published var error: String?

    struct Download: Equatable {
        enum Kind: String { case install, update, repair }
        enum State: Equatable { case queued, active, paused, failed(String) }
        var kind: Kind
        var state: State
        var progress = EADownloadProgress()
    }
    @Published var downloads: [String: Download] = [:]
    var queue: [String] = []
    var active: (id: String, task: Task<Void, Never>)?
    var inSession = false
    var resumeAfterSession = Set<String>()
    var resumeAfterBackground = Set<String>()
    var started = false
    var timer: Timer?
    var grace: UIBackgroundTaskIdentifier = .invalid
    let api = EAAPI.shared
    let downloader = EADownloader()
    /// The game whose launch Madeira prepared (its environment and service), until the session ends.
    var launched: String?

    private init() { loadInstalled() }

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ id: String) -> EAOwnedGame? { owned.first { $0.id == id } }

    // MARK: Files

    static var drive: URL { EpicLibrary.drive }
    static let installRoot = "Program Files/EA Games"
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
    }
    static var cacheURL: URL { support.appendingPathComponent("ea-library.json") }
    static var installedURL: URL { support.appendingPathComponent("ea-installed.json") }
    /// The installed build's file list, so an update keeps unchanged files without reading them.
    static func filesURL(_ id: String) -> URL {
        support.appendingPathComponent("ea-manifests", isDirectory: true).appendingPathComponent(safeName(id) + ".json")
    }
    static func journalURL(_ id: String) -> URL {
        support.appendingPathComponent("ea-downloads", isDirectory: true).appendingPathComponent(safeName(id) + ".journal")
    }
    /// A file or folder name made from EA's text: no separators, no dots at the ends.
    nonisolated static func safeName(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(120))
    }
    struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [EAOwnedGame] }
    static func accountKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Called when the library shows the EA section; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        if let session = api.account() {
            signedIn = true
            accountName = session.displayName.isEmpty ? nil : session.displayName
            loadCache(account: session.userID)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginGrace() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endGrace(); self?.resumeFromBackground() }
        }
        if signedIn, owned.isEmpty { Task { await refreshLibrary(interactive: false) } }
    }

    // MARK: Account

    /// PCI vendor ids of the GPUs Madeira's Wine reports.
    static let appleVendor: UInt16 = 0x106b, nvidiaVendor: UInt16 = 0x10de

    // MARK: Library

    var sizeRequests: [String: Task<Void, Never>] = [:]

    // MARK: Downloads

    // MARK: What starts the game

    nonisolated static let licenceFactsKey = "diagnostics.eaLicence"
    nonisolated static let hashCheckKey = "diagnostics.eaHashCheck"

    // MARK: Licence hash variant

    /// Whether the game hashed its machine before Wine registered the display adapter.
    /// Dragon Age: Inquisition (2.5.1, iPad mini A17 Pro) read its licence ("License
    /// signature is good") and still started ActivationUI.exe, and the Wine log shows
    /// `[vgpu] registered PCI\VEN_106B&DEV_0001...` only AFTER that first start: when the
    /// activation library asked WMI for Win32_VideoController.PNPDeviceID there was no
    /// adapter yet, so its hash had no "PCI" field and the licence (asked for with one)
    /// never matched. Variant 1 asks for the licence without the adapter. The variant
    /// flips after every session in which the game started ActivationUI.exe, and stays
    /// once a session ends without it, so the licence converges to the hash the game
    /// really computes.
    nonisolated static let hashVariantPrefix = "ea.licenceHashVariant."
    nonisolated(unsafe) static var lastPreparedContentID: String?
    /// The offer id of that launch, which is the game's profile id after "ea:".
    nonisolated(unsafe) static var lastPreparedOfferID: String?

    // MARK: Starting a game

    /// The environment the EA app gives a game; cleared before every other launch.
    static let environmentNames = ["EAAuthCode", "EAEgsProxyIpcPort", "EAEntitlementSource", "EAExternalSource", "EAFreeTrialGame", "EAGameLocale",
                                   "EAGenericAuthToken", "EALaunchCode", "EALaunchOwner", "EALaunchEAID", "EALaunchEnv", "EALaunchOfflineMode",
                                   "EALsxPort", "EARtPLaunchCode", "EASecureLaunchTokenTemp", "EASteamProxyIpcPort", "OriginSessionKey", "ContentId",
                                   "EAOnErrorExitRetCode", "EAConnectionId", "EALicenseToken", "EALaunchUserAuthToken", "EAAccessTokenJWS"]

    // MARK: Sessions

    var sessionRunning: Bool {
        wine_process_is_running() != 0 || wineserver_is_running() != 0
    }

}

