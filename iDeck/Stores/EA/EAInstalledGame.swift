// EAInstalledGame.swift
// Split from EALibrary.swift (iDeck 3.0 architecture).

import Foundation

/// An installed EA game, as recorded by Madeira.
struct EAInstalledGame: Codable, Sendable {
    var offerID: String
    var title: String
    /// Relative to drive_c, forward slashes: "Program Files/EA Games/Mass Effect".
    var folder: String
    var buildID: String
    var version: String
    /// The id a licence names; empty when neither the catalog nor the build said.
    var contentID: String
    var multiplayerID: String
    /// The program, relative to `folder`, forward slashes.
    var launchExe: String
    var arguments: String
    var installBytes: Int64
    /// The registry key (under HKLM, backslashes) and value the game's manifest named for
    /// its install folder, which Madeira writes so the game finds its files.
    var registryKey: String?
    var registryValue: String?

    var programPath: String { folder + "/" + launchExe }
    var windowsInstallPath: String { "C:\\" + folder.replacingOccurrences(of: "/", with: "\\") }
}
