// CompatibilityAuto.swift
// Split from WindowsEnvironment.swift (iDeck 3.0 architecture).

import Foundation
import UIKit


/// Where the last unhandled illegal instruction (0xC000001D) of a session was
/// raised, read from Wine's log. Guest code (the game, x86 or x64) runs at the
/// Windows addresses the runtime maps from 0x70_0000_0000 up; an address below
/// that is the runtime's own native code, which AVX translation cannot affect.
enum IllegalInstructionOrigin {
    static let guestBase: UInt64 = 0x70_0000_0000
    private static let marker = "Unhandled exception code c000001d"

    /// The address on the last "Unhandled exception code c000001d ... addr 0x..." line.
    static func lastAddress(in log: String) -> UInt64? {
        guard let line = log.components(separatedBy: "\n").last(where: { $0.contains(marker) }),
              let range = line.range(of: " addr 0x") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isHexDigit }
        return UInt64(digits, radix: 16)
    }

    static func isHost(address: UInt64) -> Bool { address < guestBase }

    /// True only when the log names an address and it is the runtime's own.
    static func isHost(logURL: URL?, since offset: Int64?) -> Bool {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return false }
        defer { try? handle.close() }
        if let offset, offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        guard let data = try? handle.readToEnd(),
              let address = lastAddress(in: String(decoding: data, as: UTF8.self)) else { return false }
        return isHost(address: address)
    }
}

/// Games that need AVX/AVX2 translation, found when one stops on an illegal
/// instruction (0xC000001D); kept per game, by its profile ID.
/// Games whose session ended in FEX's self-modifying-code loop: the game writes into
/// a page FEX has translated code from, FEX handles the write, and the same write
/// faults again until the fault is "redelivered" 2000 times and iDeck stops
/// (Overcooked: Gourmet Edition, GOG, 32-bit Unity). FEX's full code checks
/// (FEX_SMCCHECKS = full) do not protect pages, so the loop cannot start.
enum FullCodeChecksAuto {
    private static let key = "fullCodeChecksAutoGames"
    static let lastGameKey = "diagnostics.lastProfileID"
    /// What the Wine log says when the loop ended the session.
    static let markers = ["unrecoverable host fault misdelivered to guest"]

    static func isOn(_ game: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(game)
    }

    /// True when it was off before.
    @discardableResult
    static func enable(_ game: String) -> Bool {
        var games = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !game.isEmpty, !games.contains(game) else { return false }
        games.append(game)
        UserDefaults.standard.set(games, forKey: key)
        AppLog.record("[code-checks] \(game) looped on self-modifying code: full code checks on for it")
        return true
    }

    /// Whether the newest `bytes` of a Wine log show the loop.
    static func logShowsLoop(_ url: URL, bytes: UInt64 = 8 << 20) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > bytes ? size - bytes : 0)) != nil,
              let data = try? handle.readToEnd() else { return false }
        return markers.contains { data.range(of: Data($0.utf8)) != nil }
    }

    /// At iDeck's start, when the last session ended with the app: the game that ran
    /// gets full code checks if the Wine log shows the loop.
    static func checkAfterAppRestart(sessionWasRunning: Bool) {
        guard sessionWasRunning, let game = UserDefaults.standard.string(forKey: lastGameKey),
              let log = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("madeira-log.txt"),
              logShowsLoop(log) else { return }
        enable(game)
    }
}

enum AVXAuto {
    private static let key = "avxAutoGames"

    static func isOn(_ game: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(game)
    }

    /// True when it was off before.
    @discardableResult
    static func enable(_ game: String) -> Bool {
        var games = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !games.contains(game) else { return false }
        games.append(game)
        UserDefaults.standard.set(games, forKey: key)
        AppLog.record("[avx] \(game) stopped on an illegal instruction: AVX/AVX2 translation on for it")
        return true
    }
}
