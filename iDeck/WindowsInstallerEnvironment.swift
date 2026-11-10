import Foundation

// One way to run any Windows program or installer in iDeck's Wine prefix.
//
// Wine's own DLLs are always there (the downloaded runtime). Everything else is
// installed only when a program needs it: before it starts, its PE header is read
// (machine, imported and delay-loaded DLLs, CLR header) and the matching Microsoft
// Visual C++ runtime (by version and architecture) or Wine Mono (.NET Framework) is
// installed first. Installers are recognised by their technology (Windows Installer
// .msi, Inno Setup, NSIS, InstallShield, WiX Burn, 7-Zip SFX, Squirrel) and started
// the way that technology expects: an .msi through msiexec, the others with their own
// switches (no reboot; silent only when asked). Log tag: [installer].

// MARK: - PE

struct WindowsPEInfo: Equatable {
    var machine: UInt16
    var imports: Set<String>          // lowercased DLL names, imports + delay imports
    var isDotNet: Bool                // has a CLR (COM descriptor) header
    var sections: [String]
    var overlayOffset: Int            // end of the last section's raw data

    var is32Bit: Bool { machine == 0x014c }

    /// Reads at most `limit` bytes of `url`.
    static func read(_ url: URL, limit: Int = 64 << 20) -> WindowsPEInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 64 else { return nil }
        guard head[0] == 0x4d, head[1] == 0x5a else { return nil }
        let peOffset = Int(head.u32(0x3c))
        guard peOffset > 0, peOffset < 1 << 20 else { return nil }
        // The headers and the import tables: read the file up to the limit once.
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.read(upToCount: limit), data.count > peOffset + 24,
              data.u32(peOffset) == 0x0000_4550 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> WindowsPEInfo? {
        guard data.count > 0x40 else { return nil }
        let pe = Int(data.u32(0x3c))
        guard pe + 24 <= data.count, data.u32(pe) == 0x0000_4550 else { return nil }
        let machine = data.u16(pe + 4)
        let sectionCount = Int(data.u16(pe + 6))
        let optionalSize = Int(data.u16(pe + 20))
        let optional = pe + 24
        guard optional + optionalSize <= data.count, optionalSize >= 2 else { return nil }
        let magic = data.u16(optional)
        let directories: Int
        switch magic {
        case 0x10b: directories = optional + 96      // PE32
        case 0x20b: directories = optional + 112     // PE32+
        default: return nil
        }
        let directoryCount = Int(data.u32(directories - 4))
        func directory(_ index: Int) -> (rva: Int, size: Int) {
            guard index < directoryCount, directories + index * 8 + 8 <= data.count else { return (0, 0) }
            return (Int(data.u32(directories + index * 8)), Int(data.u32(directories + index * 8 + 4)))
        }

        struct Section { let name: String; let rva: Int; let virtualSize: Int; let raw: Int; let rawSize: Int }
        var sections: [Section] = []
        var table = optional + optionalSize
        var overlay = 0
        for _ in 0..<min(sectionCount, 96) {
            guard table + 40 <= data.count else { break }
            let nameBytes = data[(data.startIndex + table)..<(data.startIndex + table + 8)].prefix { $0 != 0 }
            let section = Section(name: String(decoding: nameBytes, as: UTF8.self),
                                  rva: Int(data.u32(table + 12)), virtualSize: Int(data.u32(table + 8)),
                                  raw: Int(data.u32(table + 20)), rawSize: Int(data.u32(table + 16)))
            sections.append(section)
            overlay = max(overlay, section.raw + section.rawSize)
            table += 40
        }
        func offset(_ rva: Int) -> Int? {
            for s in sections where rva >= s.rva && rva < s.rva + max(s.virtualSize, s.rawSize) {
                let value = s.raw + (rva - s.rva)
                return value < data.count ? value : nil
            }
            return nil
        }
        func cString(_ rva: Int) -> String? {
            guard let start = offset(rva) else { return nil }
            var end = start
            while end < data.count, end - start < 260, data[data.startIndex + end] != 0 { end += 1 }
            return String(decoding: data[(data.startIndex + start)..<(data.startIndex + end)], as: UTF8.self).lowercased()
        }

        var imports = Set<String>()
        // Import directory (1): 20-byte descriptors, name RVA at +12.
        let importDir = directory(1)
        if importDir.rva != 0, var at = offset(importDir.rva) {
            for _ in 0..<512 {
                guard at + 20 <= data.count else { break }
                let nameRVA = Int(data.u32(at + 12))
                if nameRVA == 0 && data.u32(at) == 0 { break }
                if let name = cString(nameRVA), !name.isEmpty { imports.insert(name) }
                at += 20
            }
        }
        // Delay-load directory (13): 32-byte descriptors, name RVA at +4.
        let delayDir = directory(13)
        if delayDir.rva != 0, var at = offset(delayDir.rva) {
            for _ in 0..<512 {
                guard at + 32 <= data.count else { break }
                let nameRVA = Int(data.u32(at + 4))
                if nameRVA == 0 { break }
                if let name = cString(nameRVA), !name.isEmpty { imports.insert(name) }
                at += 32
            }
        }
        let clr = directory(14)
        return WindowsPEInfo(machine: machine, imports: imports, isDotNet: clr.rva != 0 && clr.size != 0,
                             sections: sections.map(\.name), overlayOffset: overlay)
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        guard at + 2 <= count else { return 0 }
        return UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + at + $1]) << (8 * $1) }
    }
}

// MARK: - Installer technology

enum WindowsInstallerKind: String, Equatable, CaseIterable {
    case msi = "Windows Installer (MSI)"
    case innoSetup = "Inno Setup"
    case nsis = "NSIS"
    case installShield = "InstallShield"
    case wixBurn = "WiX Burn"
    case sevenZipSFX = "7-Zip self-extracting archive"
    case squirrel = "Squirrel"

    /// The switches the technology takes. Interactive installs only turn off reboots
    /// (and Inno's "This will install..." prompt); silent installs show no windows.
    func arguments(silent: Bool) -> String {
        switch self {
        case .msi: return silent ? "/qn /norestart" : "/norestart"
        case .innoSetup: return silent ? "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" : "/SP- /NORESTART"
        case .nsis: return silent ? "/S" : ""
        case .installShield: return silent ? "/s /v\"/qn /norestart\"" : ""
        case .wixBurn: return silent ? "/quiet /norestart" : "/norestart"
        case .sevenZipSFX: return silent ? "-y" : ""
        case .squirrel: return silent ? "--silent" : ""
        }
    }

    /// What `url` is: by the Windows Installer (OLE compound file) header for .msi,
    /// otherwise by the markers each technology writes into its setup program.
    static func detect(_ url: URL, pe: WindowsPEInfo?) -> WindowsInstallerKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        if head == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) { return .msi }
        guard let pe else { return nil }
        if pe.sections.contains(".wixburn") { return .wixBurn }
        // Markers sit in the resources (Inno, InstallShield, Squirrel) or right after
        // the image (the NSIS and 7-Zip payloads); scan the start and the overlay.
        try? handle.seek(toOffset: 0)
        var sample = (try? handle.read(upToCount: 8 << 20)) ?? Data()
        if pe.overlayOffset > sample.count {
            try? handle.seek(toOffset: UInt64(pe.overlayOffset))
            sample.append((try? handle.read(upToCount: 1 << 20)) ?? Data())
        }
        func has(_ marker: String) -> Bool { sample.range(of: Data(marker.utf8)) != nil }
        func hasWide(_ marker: String) -> Bool {
            sample.range(of: Data(marker.utf8.flatMap { [$0, 0] })) != nil
        }
        if has("Inno Setup Setup Data") || has("Inno Setup Messages") || hasWide("Inno Setup") { return .innoSetup }
        if has("NullsoftInst") || has("Nullsoft.NSIS") { return .nsis }
        if has("InstallShield") || hasWide("InstallShield") { return .installShield }
        if sample.range(of: Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) != nil && (has("7-Zip") || hasWide("7-Zip")) {
            return .sevenZipSFX
        }
        if has("SquirrelSetup") || hasWide("Squirrel") { return .squirrel }
        return nil
    }
}

// MARK: - Requirements

struct WindowsRequirements: Equatable {
    /// Visual C++ packages by VisualCRuntimeLegacy name ("2010 x86", "2015-2022 x86").
    var visualCPackages: Set<String> = []
    /// The x64 Visual C++ 2015-2022 runtime (VisualCRuntimeBootstrap).
    var visualC2015x64 = false
    var dotNet = false

    var isEmpty: Bool { visualCPackages.isEmpty && !visualC2015x64 && !dotNet }

    private static let versions: [(String, String)] = [("80", "2005"), ("90", "2008"), ("100", "2010"),
                                                       ("110", "2012"), ("120", "2013")]

    /// What a program's imports call for.
    static func of(_ pe: WindowsPEInfo) -> WindowsRequirements {
        var result = WindowsRequirements()
        let arch = pe.is32Bit ? "x86" : "x64"
        for (version, year) in versions {
            let names = ["msvcr\(version).dll", "msvcp\(version).dll", "mfc\(version).dll", "mfc\(version)u.dll",
                         "atl\(version).dll", "vcomp\(version).dll", "msvcm\(version).dll"]
            if names.contains(where: pe.imports.contains) { result.visualCPackages.insert("\(year) \(arch)") }
        }
        let modern = pe.imports.contains {
            $0.hasPrefix("vcruntime140") || $0.hasPrefix("msvcp140") || $0 == "concrt140.dll" || $0 == "vcomp140.dll"
                || $0 == "mfc140.dll" || $0 == "mfc140u.dll" || $0 == "vcamp140.dll" || $0 == "vccorlib140.dll"
        }
        if modern {
            if pe.is32Bit { result.visualCPackages.insert("2015-2022 x86") } else { result.visualC2015x64 = true }
        }
        result.dotNet = pe.isDotNet || pe.imports.contains("mscoree.dll")
        return result
    }
}

// MARK: - Plan and on-demand install

enum WindowsInstallerEnvironment {
    struct Plan: Equatable {
        var executable: URL                  // what Wine starts
        var arguments: String                // the technology's switches, before the profile's own
        var kind: WindowsInstallerKind?
        var requirements: WindowsRequirements
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// The Windows path of a file inside the prefix's drive_c.
    static func windowsPath(_ file: URL, prefix: URL) -> String? {
        WindowsDrivePath.relative(file, drive: prefix.appendingPathComponent("drive_c"))
    }

    static func plan(for file: URL, prefix: URL, silent: Bool = false, detectInstaller: Bool = true) -> Plan? {
        let pe = WindowsPEInfo.read(file)
        let kind = detectInstaller || file.pathExtension.lowercased() == "msi" ? WindowsInstallerKind.detect(file, pe: pe) : nil
        if kind == .msi {
            guard let path = windowsPath(file, prefix: prefix) else { return nil }
            let msiexec = prefix.appendingPathComponent("drive_c/windows/system32/msiexec.exe")
            return Plan(executable: msiexec, arguments: "/i \"\(path)\" " + WindowsInstallerKind.msi.arguments(silent: silent),
                        kind: .msi, requirements: WindowsRequirements())
        }
        guard let pe else { return nil }
        return Plan(executable: file, arguments: kind?.arguments(silent: silent) ?? "", kind: kind,
                    requirements: WindowsRequirements.of(pe))
    }

    /// What of `requirements` is not installed yet.
    @MainActor static func missing(_ requirements: WindowsRequirements) -> WindowsRequirements {
        var result = WindowsRequirements()
        let root = documents.appendingPathComponent("vcruntime", isDirectory: true)
        for name in requirements.visualCPackages {
            guard let package = VisualCRuntimeLegacy.packages.first(where: { $0.name == name }),
                  let relative = VisualCRuntimeLegacy.destination(package.required, machine: package.machine) else { continue }
            let installedHere = FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
            if !installedHere && !VisualCRuntimeLegacy.installed(documents: documents) { result.visualCPackages.insert(name) }
        }
        if requirements.visualC2015x64,
           !VisualCRuntimeBootstrap.installed(in: MadeiraDock.prefix, documents: documents) {
            result.visualC2015x64 = true
        }
        if requirements.dotNet && !WineMonoModel.available { result.dotNet = true }
        return result
    }

    /// Installs what `requirements` lists and is missing. Returns the failures.
    @MainActor static func install(_ requirements: WindowsRequirements,
                                   progress: @escaping @MainActor (String) -> Void) async -> [String] {
        let needed = missing(requirements)
        var failures: [String] = []
        if needed.visualC2015x64 {
            progress("Installing Visual C++ 2015-2022 x64…")
            AppLog.record("[installer] installing Visual C++ 2015-2022 x64")
            if !VisualCRuntimeBootstrap.installBundled(documents: documents) {
                if let failure = await downloadVisualC2015x64() { failures.append(failure) }
            }
        }
        for package in VisualCRuntimeLegacy.packages where needed.visualCPackages.contains(package.name) {
            progress("Installing Visual C++ \(package.name)…")
            AppLog.record("[installer] installing Visual C++ \(package.name)")
            do {
                let installer = try await VisualCRuntimeLegacy.download(package)
                defer { try? FileManager.default.removeItem(at: installer) }
                _ = try VisualCRuntimeLegacy.extract(package, installer: installer, documents: documents)
            } catch {
                failures.append("Visual C++ \(package.name): \(error.localizedDescription)")
            }
        }
        if needed.dotNet {
            progress("Installing .NET support (Wine Mono)…")
            AppLog.record("[installer] installing Wine Mono")
            let mono = WineMonoModel.shared
            mono.install()
            while mono.busy {
                progress(mono.status)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !WineMonoModel.available { failures.append(mono.error ?? "Wine Mono was not installed.") }
        }
        for failure in failures { AppLog.record("[installer] \(failure)") }
        return failures
    }

    private static func downloadVisualC2015x64() async -> String? {
        await withCheckedContinuation { continuation in
            VisualCRuntimeBootstrap.download(in: MadeiraDock.prefix) { result in
                switch result {
                case .failure(let error):
                    continuation.resume(returning: error.localizedDescription)
                case .success(let installer):
                    VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: documents) { outcome in
                        try? FileManager.default.removeItem(at: installer)
                        if case .failure(let error) = outcome {
                            continuation.resume(returning: error.localizedDescription)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        }
    }
}
