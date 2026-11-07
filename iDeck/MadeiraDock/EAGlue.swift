import Foundation

// iDeck glue for Madeira's EA support (Vendor/Madeira/SwiftEA, EALibrary.swift).
// The pinned Madeira Dock files predate SteamInstallRegistry, so the registry
// values an EA game expects are written here. The text escaping follows
// Madeira's SteamInstallRegistry (8b52c18), which follows wineserver's
// server/unicode.c dump_strW.

/// One registry value to put into the prefix.
struct SteamInstallValue: Equatable, Sendable {
    enum Content: Equatable, Sendable { case string(String), dword(UInt32) }
    var hive: SteamInstallRun.Hive
    var key: String      // under the hive, backslashes: "Software\\Electronic Arts\\EA Desktop"
    var name: String     // "" is the key's default value
    var data: Content
    var followsInstall: Bool   // rewritten when it differs (an install folder)
}

enum EARegistry {
    static func line(_ value: SteamInstallValue) -> String {
        let name = value.name.isEmpty ? "@" : "\"" + text(value.name, quote: "\"") + "\""
        switch value.data {
        case .string(let string): return name + "=\"" + text(string, quote: "\"") + "\""
        case .dword(let number): return name + String(format: "=dword:%08x", number)
        }
    }

    static func text(_ string: String, quote: String) -> String {
        let units = Array(string.utf16)
        let escapes = Array(".......abtnvfr.............e....".utf8)
        var out = ""
        for (index, unit) in units.enumerated() {
            let next = index + 1 < units.count ? units[index + 1] : nil
            if unit > 127 {
                let hexNext = next.map { $0 < 128 && Character(Unicode.Scalar(UInt8($0))).isHexDigit } ?? false
                out += hexNext ? String(format: "\\x%04x", UInt32(unit)) : String(format: "\\x%x", UInt32(unit))
            } else if unit < 32 {
                if escapes[Int(unit)] != UInt8(ascii: ".") { out += "\\" + String(Character(Unicode.Scalar(escapes[Int(unit)]))) }
                else if let next, next >= 48, next <= 55 { out += String(format: "\\%03o", UInt32(unit)) }
                else { out += String(format: "\\%o", UInt32(unit)) }
            } else {
                let character = Character(Unicode.Scalar(UInt8(unit)))
                if character == "\\" || quote.contains(character) { out += "\\" }
                out.append(character)
            }
        }
        return out
    }

    /// Both registry views of an HKLM\Software key; a user key as it is.
    static func keys(_ hive: SteamInstallRun.Hive, _ key: String) -> [String] {
        guard hive == .machine else { return [key] }
        let lower = key.lowercased()
        guard lower.hasPrefix("software\\"), !lower.hasPrefix("software\\wow6432node\\") else { return [key] }
        return [key, "Software\\Wow6432Node\\" + key.dropFirst("Software\\".count)]
    }

    /// The .reg text with the values in it, and how many lines changed. A present value
    /// stays unless it follows the install folder and differs.
    static func write(_ values: [SteamInstallValue], in text: String, now: Int) -> (text: String, changed: Int) {
        var lines = text.components(separatedBy: "\n")
        var changed = 0
        for value in values {
            let wanted = line(value)
            let namePrefix = value.name.isEmpty ? "@=" : "\"" + Self.text(value.name, quote: "\"").lowercased() + "\"="
            for key in keys(value.hive, value.key) {
                let header = "[" + Self.text(key, quote: "[]") + "]"
                if let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header.lowercased()) }) {
                    var end = start + 1
                    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                    if let index = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(namePrefix) }) {
                        guard value.followsInstall, lines[index] != wanted else { continue }
                        lines[index] = wanted
                    } else {
                        var at = end
                        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
                        lines.insert(wanted, at: at)
                    }
                } else {
                    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
                    lines += ["", header + " \(now)", wanted, ""]
                }
                changed += 1
            }
        }
        return (lines.joined(separator: "\n"), changed)
    }

    /// Writes the values into the prefix's system.reg / user.reg (only while no session
    /// runs, as EALibrary checks). Returns the number of lines changed.
    @discardableResult
    static func write(_ values: [SteamInstallValue], prefix: URL) throws -> Int {
        let now = Int(Date().timeIntervalSince1970)
        var total = 0
        for hive in Set(values.map(\.hive)) {
            let file = prefix.appendingPathComponent(hive == .machine ? "system.reg" : "user.reg")
            let original = try String(contentsOf: file, encoding: .utf8)
            let result = write(values.filter { $0.hive == hive }, in: original, now: now)
            guard result.changed > 0 else { continue }
            try Data(result.text.utf8).write(to: file, options: .atomic)
            total += result.changed
        }
        return total
    }
}
