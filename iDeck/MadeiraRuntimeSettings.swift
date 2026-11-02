// Ported from willfaust/Madeira app/Madeira/Library.swift (c2c1b03):
// SyncEngine and RuntimeMemorySyncSettings, GPL-3.0-or-later.
import Metal
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

// Ported from Madeira app/Madeira/Library.swift (GraphicsSettings), line by line; LogStore -> AppLog.
struct MadeiraGraphicsSettings: View {
    static let shown = MadeiraConfig.flag("MADEIRA_GRAPHICS_SETTINGS")   // 0: no Settings › Graphics section; d3d9, d3d11, d3d12 and vulkan are back in All settings
    static let keys: Set<String> = ["d3d9", "d3d11", "d3d12", "vulkan"]
    static let glBackendKey = "gl-backend"
    /// The keys All settings and the Settings search leave to this section.
    static var featuredKeys: Set<String> { shown ? keys : [] }
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0

    static let d3d9Choices: [(String, String)] = [
        ("", "DXMT (default)"), ("native", "DXMT native frontend (32-bit)"), ("wined3d", "Wine wined3d on OpenGL (Zink)"),
    ]
    static let d3d11Choices: [(String, String)] = [("", "DXMT (default)"), ("dxvk", "DXVK on Vulkan (experimental)")]
    static let d3d12Choices: [(String, String)] = [("", "madeira-d3d12 (default)"), ("vkd3d", "vkd3d-proton on Vulkan")]
    static let vulkanChoices: [(String, String)] = [("", "Automatic"), ("moltenvk", "MoltenVK"), ("kosmickrisp", "KosmicKrisp")]

    static func bundled(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent(path).path)
    }
    /// gl/libvulkan_kosmickrisp.dylib (docs/KOSMICKRISP.md); without it vulkan = kosmickrisp keeps Vulkan off.
    static let hasKosmicKrisp = bundled("gl/libvulkan_kosmickrisp.dylib")
    /// vkd3d-proton's DLLs are git-ignored build products (build/vkd3d-proton/build.sh).
    static let hasVkd3d = bundled("vulkan/arm64ec-windows/d3d12.dll") && bundled("vulkan/arm64ec-windows/d3d12core.dll")
    /// DXVK's DLLs are git-ignored build products too (build/dxvk/build.sh, docs/DXVK.md).
    static let hasDxvk = ["d3d11", "d3d10core", "dxgi"].allSatisfy { bundled("vulkan/arm64ec-windows/dxvk-\($0).dll") }
    /// The Zink OpenGL backend's library; without it the default backend is OpenGL ES, where wined3d finds no context.
    static let hasZink = bundled("gl/libOSMesa.dylib")
    /// KosmicKrisp takes the first Metal 4 device: iOS 26 with an A14 or newer.
    static let metal4: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26.0, *) { return MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) ?? false }
        return false
        #endif
    }()

    /// The stored value, trimmed and lowercased, "" when unset; d3d9 "emulated" is the default.
    static func current(_ key: String) -> String {
        let v = (MadeiraConfig.get(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return key == "d3d9" && v == "emulated" ? "" : v
    }
    static var anySet: Bool { keys.contains { MadeiraConfig.get($0) != nil } }

    @State private var d3d9 = Self.current("d3d9")
    @State private var d3d11 = Self.current("d3d11")
    @State private var d3d12 = Self.current("d3d12")
    @State private var vulkan = Self.current("vulkan")
    @State private var anySet = Self.anySet

    private func reload() {
        d3d9 = Self.current("d3d9"); d3d11 = Self.current("d3d11"); d3d12 = Self.current("d3d12")
        vulkan = Self.current("vulkan")
        anySet = Self.anySet
    }

    private func write(_ key: String, _ value: String?) {
        _ = MadeiraConfig.set(key, value)
        anySet = Self.anySet
        AppLog.record("[graphics-settings] \(key)=\(value ?? "(default)")")
    }

    /// A menu picker over `choices`; a stored value that is not one of them stays selectable as itself.
    private func choicePicker(_ title: String, key: String, value: Binding<String>, choices: [(String, String)],
                              other: (String) -> String = { "Other (\($0))" }) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue }, set: { choice in
            value.wrappedValue = choice
            write(key, choice.isEmpty ? nil : choice)
        })) {
            ForEach(choices, id: \.0) { Text($0.1).tag($0.0) }
            if !choices.contains(where: { $0.0 == value.wrappedValue }) { Text(other(value.wrappedValue)).tag(value.wrappedValue) }
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
    }

    private var d3d9Note: String {
        switch d3d9 {
        case "": return "DXMT draws Direct3D 9 on Metal; 32-bit games run its frontend through the x86 translator."
        case "native": return "32-bit games run DXMT's Direct3D 9 frontend as native ARM64 code; 64-bit games are unchanged."
        case "wined3d": return "Experimental: 32- and 64-bit games use Wine's own Direct3D 9 on OpenGL, which needs the Zink OpenGL backend."
        default: return "A value Madeira does not know; Direct3D 9 games use DXMT."
        }
    }
    private var d3d11Note: String {
        switch d3d11 {
        case "": return "DXMT draws Direct3D 10 and 11 on Metal."
        case "dxvk": return "Experimental, 64-bit games only: Direct3D 10/11 and DXGI run through DXVK on Vulkan (MoltenVK unless a Vulkan driver is chosen below). Direct3D 12 then uses vkd3d-proton."
        default: return "A value Madeira does not know; Direct3D 10/11 games use DXMT."
        }
    }
    private var d3d12Note: String {
        switch d3d12 {
        case "" where d3d11 == "dxvk": return "With DXVK chosen above, Direct3D 12 games use vkd3d-proton on Vulkan: DXVK's DXGI shows only Vulkan devices."
        case "": return "Direct3D 12 games run on madeira-d3d12, Madeira's own Direct3D 12 on Metal."
        case "vkd3d": return "Experimental, 64-bit games only: Direct3D 12 runs through vkd3d-proton on Vulkan (MoltenVK unless a Vulkan driver is chosen below)."
        default: return "A developer value; Direct3D 12 games run on madeira-d3d12."
        }
    }
    private var vulkanNote: String {
        switch vulkan {
        case "": return "Off, so games find no Vulkan, unless DXVK or vkd3d-proton is chosen above, which turns on MoltenVK."
        case "moltenvk": return "64-bit games get Vulkan through MoltenVK, the driver the Zink OpenGL backend also uses."
        case "kosmickrisp": return "Experimental: 64-bit games get Vulkan through Mesa's KosmicKrisp driver. Needs iOS 26 and an A14 chip or newer."
        case "off", "0": return "Off: games find no Vulkan, and DXVK and vkd3d-proton are not used even when chosen above."
        default: return "A Vulkan library named by path in madeira.cfg."
        }
    }

    var body: some View {
        Section {
            choicePicker("Direct3D 9", key: "d3d9", value: $d3d9, choices: Self.d3d9Choices)
            note(d3d9Note)
            if d3d9 == "wined3d" {
                let backend = (MadeiraConfig.get(Self.glBackendKey) ?? "").lowercased()
                if !Self.hasZink || (!backend.isEmpty && backend != "zink") {
                    note(Self.hasZink ? "madeira.cfg sets gl-backend = \(backend); wined3d needs gl-backend = zink."
                                      : "This build has no Zink OpenGL backend (gl/ folder), so wined3d cannot start.", warning: true)
                }
            }

            choicePicker("Direct3D 10/11", key: "d3d11", value: $d3d11,
                         choices: Self.hasDxvk || d3d11 == "dxvk" ? Self.d3d11Choices : Array(Self.d3d11Choices.prefix(1)))
            note(d3d11Note)
            if !Self.hasDxvk { note("DXVK is not in this build.", warning: d3d11 == "dxvk") }
            if d3d11 == "dxvk" && !d3d12.isEmpty && d3d12 != "vkd3d" {
                note("Direct3D 12 is set to \(d3d12); with DXVK only vkd3d-proton can show Direct3D 12 games.", warning: true)
            }

            choicePicker("Direct3D 12", key: "d3d12", value: $d3d12,
                         choices: Self.hasVkd3d || d3d12 == "vkd3d" ? Self.d3d12Choices : Array(Self.d3d12Choices.prefix(1)))
            note(d3d12Note)
            if !Self.hasVkd3d { note("vkd3d-proton is not in this build.", warning: d3d12 == "vkd3d") }

            choicePicker("Vulkan driver", key: "vulkan", value: $vulkan,
                         choices: Self.hasKosmicKrisp || vulkan == "kosmickrisp" ? Self.vulkanChoices : Array(Self.vulkanChoices.prefix(2)),
                         other: { $0 == "off" || $0 == "0" ? "Off" : "Custom library" })
            note(vulkanNote)
            if !Self.hasKosmicKrisp {
                note("KosmicKrisp is not in this build (no gl/libvulkan_kosmickrisp.dylib).", warning: vulkan == "kosmickrisp")
            } else if !Self.metal4 {
                note("This device has no Metal 4 GPU, so KosmicKrisp cannot start on it.", warning: vulkan == "kosmickrisp")
            }

            Button("Reset to defaults") {
                for key in Self.keys.sorted() { _ = MadeiraConfig.set(key, nil) }
                AppLog.record("[graphics-settings] reset: d3d9, d3d11, d3d12 and vulkan removed")
                reload()
            }
            .disabled(!anySet)
        } header: { Text("Graphics") } footer: {
            Text("These write d3d9 / d3d11 / d3d12 / vulkan into madeira.cfg; changes apply at the next session start. A game's own settings still win for that game.")
        }
        .onChange(of: refresh) { _, _ in reload() }
    }
}

