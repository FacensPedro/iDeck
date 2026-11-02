// Ported from willfaust/Madeira app/Madeira/Library.swift (c2c1b03):
// SyncEngine and RuntimeMemorySyncSettings, GPL-3.0-or-later.
import SwiftUI

/// The in-process synchronisation engine, one per session. Fastsync is the default:
/// madeira.cfg with neither inproc-sync nor env.MADEIRA_FASTSYNC, for which the app
/// exports MADEIRA_FASTSYNC=auto. Madsync is inproc-sync = 1; Wine standard sync is
/// inproc-sync = 0 without a fastsync value. Mirrors madeira_cfg_sync_engine
/// (build/madeira_cfg.h). Wine reads both once per app run.
enum MadeiraSyncEngine: String, CaseIterable, Identifiable {
    case madsync, fastsync, wine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .madsync: return "Madsync"
        case .fastsync: return tr("Fastsync (default)")
        case .wine: return tr("Wine standard sync")
        }
    }
    /// The MADEIRA_FASTSYNC values Wine treats as "fastsync on" (sync.c, event.c).
    static let fastsyncValues: Set<String> = ["1", "on", "yes", "auto", "cells"]
    static var current: MadeiraSyncEngine {
        let inproc = MadeiraConfig.get("inproc-sync")
        if inproc != nil && MadeiraConfig.bool("inproc-sync", default: false) { return .madsync }
        if let fast = MadeiraConfig.get("env.MADEIRA_FASTSYNC") { return fastsyncValues.contains(fast) ? .fastsync : .wine }
        return inproc == nil ? .fastsync : .wine
    }
    static func apply(_ engine: MadeiraSyncEngine) {
        switch engine {
        case .madsync: _ = MadeiraConfig.set("inproc-sync", "1"); _ = MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        case .fastsync: _ = MadeiraConfig.set("inproc-sync", nil); _ = MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        case .wine: _ = MadeiraConfig.set("inproc-sync", "0"); _ = MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
        }
    }
}

/// Settings › Memory & sync, as Madeira's: the video memory budget (vram-mb), the
/// file-backed swap tier (swap-mb, off by default, and env.MADEIRA_SWAP_COVERAGE,
/// which allocations it backs), the sync engine and Eco mode, all in
/// Documents/madeira.cfg, which iDeck's linked Madeira runtime reads. The JIT pool
/// keeps iDeck's own setting. Changes apply after iDeck restarts.
struct MadeiraMemorySyncSettings: View {
    static let vramChoices = [0, 512, 1024, 1536, 2048, 3072, 4096, 4352, 4608, 5120, 6144]   // 0 = automatic
    static let swapChoices = [0, 1024, 2048, 3072, 4096]
    static let coverageChoices: [(String, String)] = [
        ("", "Large allocations (8 MB+)"), ("blocks", "All allocations of 1 MB+"), ("wide", "1 MB+ and overflow"),
        ("broad", "Whole reservations 4 MB+ (broad)"),
    ]
    @State private var vramMB = Self.intKey("vram-mb")
    @State private var swapMB = Self.intKey("swap-mb")
    @State private var coverage = Self.currentCoverage()
    @State private var engine = MadeiraSyncEngine.current
    @State private var eco = MadeiraConfig.bool("eco", default: false)
    @State private var changed = false

    static func intKey(_ key: String) -> Int { Int(MadeiraConfig.get(key) ?? "") ?? 0 }
    static func currentCoverage() -> String {
        let v = (MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") ?? "").lowercased()
        if v.isEmpty { return swapModeBroad ? "broad" : "" }
        return v == "classic" ? "" : v
    }
    static var swapModeBroad: Bool { (Int(MadeiraConfig.get("swap-mode") ?? "") ?? 1) >= 2 }
    static func gb(_ mb: Int) -> String { String(format: "%g GB", Double(mb) / 1024) }

    private func mbPicker(_ title: String, key: String, value: Binding<Int>, choices: [Int],
                          zero: String, label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue }, set: { mb in
            value.wrappedValue = mb; changed = true
            _ = MadeiraConfig.set(key, mb > 0 ? String(mb) : nil)
            AppLog.record("[runtime-settings] \(key)=\(mb)")
        })) {
            ForEach(choices, id: \.self) { mb in Text(mb == 0 ? zero : label(mb)).tag(mb) }
            if !choices.contains(value.wrappedValue) { Text("\(value.wrappedValue) MB").tag(value.wrappedValue) }
        }
    }

    var body: some View {
        Section {
            mbPicker(tr("Video memory"), key: "vram-mb", value: $vramMB, choices: Self.vramChoices,
                     zero: tr("Automatic"), label: Self.gb)
            mbPicker(tr("Swap tier"), key: "swap-mb", value: $swapMB, choices: Self.swapChoices,
                     zero: tr("Off"), label: Self.gb)
            Picker(tr("Swap coverage"), selection: Binding(get: { coverage }, set: { mode in
                coverage = mode; changed = true
                _ = MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", mode.isEmpty ? (Self.swapModeBroad ? "classic" : nil) : mode)
                AppLog.record("[runtime-settings] swap-coverage=\(mode.isEmpty ? "classic" : mode)")
            })) {
                ForEach(Self.coverageChoices, id: \.0) { Text(tr($0.1)).tag($0.0) }
                if !Self.coverageChoices.contains(where: { $0.0 == coverage }) { Text(coverage).tag(coverage) }
            }
            .disabled(swapMB == 0)
            Picker(tr("Sync engine"), selection: Binding(get: { engine }, set: { choice in
                engine = choice; changed = true
                MadeiraSyncEngine.apply(choice)
                AppLog.record("[runtime-settings] sync-engine=\(choice.rawValue)")
            })) {
                ForEach(MadeiraSyncEngine.allCases) { Text($0.label).tag($0) }
            }
            Toggle(tr("Eco mode"), isOn: Binding(get: { eco }, set: { on in
                eco = on; changed = true
                _ = MadeiraConfig.set("eco", on ? "1" : nil)
                AppLog.record("[runtime-settings] eco=\(on ? 1 : 0)")
            }))
        } header: { Text(tr("Memory & sync")) } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Video memory is how much graphics memory games are told they have. Automatic sizes it from the memory free at launch. Too high can get iDeck closed for using too much memory; too low makes games keep reloading textures."))
                Text(tr("Swap tier moves game data to a file on this device's storage when memory runs short, up to the chosen size, at some speed cost. Coverage decides which allocations it moves: large ones only (8 MB and up, the default), every allocation of 1 MB and up, or those plus allocations that overflow the game's address range. Broad backs every new reservation of 4 MB and up."))
                Text(tr("Sync engine: Fastsync (the default) handles events and semaphores in-process. Madsync is the older in-process engine. Wine standard sync uses neither."))
                Text(tr("Eco mode starts every game with its threads at a low priority, which saves power but makes games run slower."))
                if changed { Text(tr("Restart iDeck (close it from the app switcher) for these changes to apply.")).foregroundStyle(.orange) }
            }
        }
    }
}
