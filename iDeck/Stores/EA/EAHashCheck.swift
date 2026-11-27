// EAHashCheck.swift
// Split from EALibrary.swift (iDeck 3.0 architecture).

import Foundation
import UIKit


/// What the licence's machine hash was built from (EAHardwareProfile), next to what the
/// prefix's own files say the game will read: Windows' ProductId and the display
/// adapters in the registry (system.reg), and the volume serial kept in the prefix. A
/// licence whose hash input differs from the game's is refused, and the game opens EA's
/// activation window.
enum EAHashCheck {
    /// The fields of each hash version the prefix's files can confirm. The board and
    /// BIOS (IOKit) and the processor (FEX's CPUID) are not in them: Wine keeps
    /// Hardware\Description volatile, so the hashed text itself records what the
    /// licence was asked for.
    static func usedFields(version: Int) -> Set<String> {
        switch version {
        case 0, 1: return ["osSerial"]
        case 2: return ["osSerial", "volume", "gpu"]
        default: return ["volume", "gpu"]
        }
    }

    static func report(profile: EAHardwareProfile, hashVersion: Int, drive: URL) -> String {
        var notes = ["hashed \"" + profile.shownHashInput(version: hashVersion) + "\""]
        let prefix = drive.deletingLastPathComponent()
        let used = usedFields(version: hashVersion)
        if used.contains("volume") {
            let letter = EAHardware.driveLetter(prefix: prefix, drive: drive)
            let stored = FileManager.default.fileExists(atPath: prefix.appendingPathComponent(EAVolumeSerial.fileName).path)
            notes.append("volume serial: " + (stored ? "the prefix's" : "none stored in the prefix") + ", drive "
                         + (letter == 0 ? "not among dosdevices" : String(UnicodeScalar(letter)) + ":"))
        }
        let registry = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        guard !registry.isEmpty else { return (notes + ["no system.reg in the prefix to compare with"]).joined(separator: " | ") }
        if used.contains("osSerial") {
            let mine = profile.osSerial.trimmingCharacters(in: .whitespaces)
            if let wine = registryValue(registry, key: "Software\\Microsoft\\Windows NT\\CurrentVersion", name: "ProductId")?
                .trimmingCharacters(in: .whitespaces) {
                notes.append(wine == mine ? "ProductId agrees" : "differs: osSerial iDeck=\"\(mine)\" wine=\"\(wine)\"")
            } else {
                notes.append("ProductId not in system.reg")
            }
        }
        if used.contains("gpu") {
            let devices = displayDevices(registry)
            notes.append(devices.isEmpty ? "no display adapter in system.reg yet"
                         : "display adapters in system.reg: \(devices.count), first \(devices[0])")
        }
        return notes.joined(separator: " | ")
    }

    /// The display adapters in a prefix registry (Enum keys of the Display class), in key
    /// order, each as its first HardwareID. Wine's wbemprox answers Win32_VideoController
    /// from these, and the licence hash takes the first one's PNPDeviceID.
    static func displayDevices(_ text: String) -> [String] {
        let enumPrefix = "[system\\\\currentcontrolset\\\\enum\\\\"
        let displayClass = "{4d36e968-e325-11ce-bfc1-08002be10318}"
        var found: [(key: String, id: String)] = []
        var key: String?
        var isDisplay = false
        var hardwareID: String?
        func close() {
            if let key, isDisplay { found.append((key, hardwareID ?? "(no HardwareID)")) }
            key = nil
            isDisplay = false
            hardwareID = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("[") {
                close()
                let lower = raw.lowercased()
                if lower.hasPrefix(enumPrefix), let end = lower.firstIndex(of: "]") {
                    key = String(lower[lower.index(after: lower.startIndex)..<end])
                }
                continue
            }
            guard key != nil, raw.hasPrefix("\"") else { continue }
            let lower = raw.lowercased()
            if lower.hasPrefix("\"classguid\"=\""), lower.contains(displayClass) { isDisplay = true }
            if lower.hasPrefix("\"hardwareid\"="), let open = raw.range(of: ":\"") ?? raw.range(of: "=\"") {
                hardwareID = firstString(raw[open.upperBound...])
            }
        }
        close()
        return found.sorted { $0.key < $1.key }.map(\.id)
    }

    /// The first string of a .reg value's quoted text: up to its closing quote or the
    /// \0 that separates the strings of a multi-string.
    static func firstString(_ quoted: Substring) -> String {
        var out = ""
        var escaped = false
        for character in quoted {
            if escaped {
                if character == "0" { break }
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// A string value from a Wine .reg file: the key's section, then `"name"="value"`.
    static func registryValue(_ text: String, key: String, name: String) -> String? {
        // Section headers double their backslashes: [Software\\Microsoft\\Windows NT\\CurrentVersion] 1700000000
        let header = "[" + key.lowercased().replacingOccurrences(of: "\\", with: "\\\\") + "]"
        var inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inside = line.lowercased().hasPrefix(header)
                continue
            }
            guard inside, line.hasPrefix("\"\(name)\"=\"") else { continue }
            var value = String(line.dropFirst(name.count + 4))
            if value.hasSuffix("\"") { value.removeLast() }
            return value.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }
}
